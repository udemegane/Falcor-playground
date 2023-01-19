#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSamplerHelpers;

cbuffer CB
{
    uint gFrameCount;
    uint gPRNGDimention;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float4> gMVec;

RWTexture2D<float4> gOutColor;

#define is_valid(name) (is_valid_##name != 0)
static const uint kRISSampleNums;
static const bool kUseReSTIR;
static const bool kUseTemporalReuse;
static const bool kUseSpatialReuse;

struct ShadowRayData
{
    bool visible;
}

struct RISReservoir<S>
{
    float wSum;
    S x;
    uint M;
    float3 pTarget;

    __init()
    {
        this.wSum = 0;
        this.pTarget = float3(0.f);
        this.M = 0;
    }
}

void UpdateReservoir<S>(inout RISReservoir<S> r, S xi, float wi, float3 pi, float rand)
{
    r.wSum += wi;
    r.M++;
    if (wi / r.wSum > rand)
    {
        r.x = xi;
        r.pTarget = pi;
    }
};

float3 calcReserviorWeight<S>(in RISReservoir<S> r)
{
    return r.wSum / (r.pTarget * r.M);
}

// RISReservoir<S> combineReservoirs<S>(RISReservoir<S>[] rs, ) {

// }

float3 getPrimaryRayDir(uint2 pixel, uint2 screen, const Camera camera)
{
    if (is_valid(gViewW))
    {
        return -gViewW[pixel].xyz;
    }
    else
    {
        return camera.computeRayPinhole(pixel, screen).dir;
    }
}

ShadingData loadShadingData(const HitInfo hitInf, const float3 rayOrigin, const float3 rayDir, const ITextureSampler lod)
{
    VertexData vd = {};
    uint matID = 0;

    if (hitInf.getType() == HitType::Triangle)
    {
        const TriangleHit th = hitInf.getTriangleHit();
        vd = gScene.getVertexData(th);
        matID = gScene.getMaterialID(th.instanceID);
    }

    if (hitInf.getType() == HitType::DisplacedTriangle)
    {
        const DisplacedTriangleHit dth = hitInf.getDisplacedTriangleHit();
        vd = gScene.getVertexData(dth, -rayDir);
        matID = gScene.getMaterialID(dth.instanceID);
    }
    if (hitInf.getType() == HitType::Curve)
    {
        const CurveHit ch = hitInf.getCurveHit();
        vd = gScene.getVertexDataFromCurve(ch);
        matID = gScene.getMaterialID(ch.instanceID);
    }
    if (hitInf.getType() == HitType::SDFGrid)
    {
        const SDFGridHit sh = hitInf.getSDFGridHit();
        vd = gScene.getVertexDataFromSDFGrid(sh, rayOrigin, rayDir);
        matID = gScene.getMaterialID(sh.instanceID);
    }
    return gScene.materials.prepareShadingData(vd, matID, -rayDir, lod);
}

bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = FLT_MAX;
    ShadowRayData rayData = { false };
    TraceRay(gScene.rtAccel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff, 1, rayTypeCount, 1, ray, rayData);
    return rayData.visible;
}

float3 evalDirectAnalytic(const ShadingData sd, const IBSDF bsdf, ISampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return float3(0.f);
    uint lightIndex = 0;
    float invPdf = 0;
    if (!kUseReSTIR)
    {
        lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
        invPdf = lightCount;
    }
    else
    {
        RISReservoir<uint> r = RISReservoir<uint>();
        for (uint i = 0; i < kRISSampleNums; i++)
        {
            const uint xi = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
            AnalyticLightSample ls;
            if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls))
                r.pTarget = float3(0.f);
            else
                r.pTarget = bsdf.eval(sd, ls.dir, sg) * ls.Li * lightCount;
            // float wi = r.pTarget
            // TODO
        }
    }
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls))
        return float(0.f);
    const uint lobeTypes = bsdf.getLobes(sd);

    if (dot(ls.dir, sd.N) <= kMinCosTheta && !(lobeTypes & (uint)LobeType::Transmission))
        return float3(0.f);
    if (dot(ls.dir, sd.N) >= -kMinCosTheta && !(lobeTypes & (uint)LobeType::Reflection))
        return float3(0.f);

    float3 n = dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN;
    float3 origin = computeRayOrigin(sd.posW, n);
    if (!traceShadowRay(origin, ls.dir, ls.distance))
        return float3(0.f);
    return bsdf.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

float3 tracePath(uint2 pixel, uint2 screen)
{
    float3 out = float3(0.f);
    const float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        const bool isCurveHit = hit.getType() == HitType::Curve;
        let lod = ExplicitLodTextureSampler(0.f);

        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let bsdf = gScene.materials.getBSDF(sd, lod);
        let sg = SampleGenerator(pixel, gFrameCount);
        for (uint i = 0; i < gPRNGDimention; i++)
            sampleNext1D(sg);
        float3 rayOrigin = sd.computeNewRayOrigin();

        out = evalDirectAnalytic(sd, bsdf, sg) + bsdf.getProperties(sd).emission;
    }
    else
    {
        out = gScene.envMap.eval(primaryRayDir);
    }
    return out;
}

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    rayData.visible = true;
}

[shader("anyhit")]
void shadowTriangleMeshAnyHit(inout ShadingData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
        IgnoreHit();
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
    float3 color = tracePath(pixel, frameDim);
    gOutColor[pixel] = float4(color, 1.0f);
}
