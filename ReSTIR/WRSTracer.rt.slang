#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

// __exported importで補完が効かない
import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Reservoir;
import RaytraceUtils;

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint gPRNGDimension;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;

// InOut
// RWStructuredBuffer<RISReservoir> prevFrameReservoir;
RWStructuredBuffer<RISReservoir> outputReservoir;
// RWStructuredBuffer<Params> params;

// Output
RWTexture2D<float4> gOutputColor;

#define is_valid(name) (is_valid_##name != 0)

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayMax = FLT_MAX;

// ReSTIR constant values
static const bool kUseReSTIR = USE_RESTIR;
static const uint kRISSampleNums = RIS_SAMPLE_NUMS;
static const bool kUseTemporalReuse = USE_TEMPORAL_REUSE;
static const uint kTemporalReuseMaxM = TEMPORAL_REUSE_MAX_M;
static const bool kUseAutoSetMaxM = USE_AUTO_SET_MAX_M;
static const bool kUseSpatialReuse = USE_SPATIAL_REUSE;

// shadow ray strcuture
struct ShadowRayData
{
    bool visible;
}

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

bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = distance;

    ShadowRayData rayData;
    rayData.visible = false; // Set to true by miss shader if ray is not terminated before
    TraceRay(gScene.rtAccel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff /* instanceInclusionMask */, 1 /* hitIdx */, rayTypeCount, 1 /* missIdx */, ray, rayData);

    return rayData.visible;
}

float3 evalDirectAnalytic(const uint2 pixel, const uint2 screen, const ShadingData sd, const IBSDF bsdf, SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return float3(0.f);
    if (kUseReSTIR)
    {

        RISReservoir r = RISReservoir();
        float2 seed = sampleNext2D(sg);
        float rand = randSimple(seed);
        for (uint i = 0; i < kRISSampleNums; i++)
        {
            // Sample LightID from uniform distribution
            const uint xi = min(uint(rand * lightCount), lightCount - 1);

            AnalyticLightSample ls;
            // Calculate from target distribution Fs*G*Li
            float3 pi3f = float3(0.000001f);
            if (sampleLight(sd.posW, gScene.getLight(xi), sg, ls))
                pi3f = bsdf.eval(sd, ls.dir, sg) * ls.Li;

            // Calculate weight proportional to p(xi)/q(xi).
            // q() is uniform distribution, Always Return 1/LightCount.
            // p(xi) is Fs*G*Li. (exclude V())
            // So weight is pi * lightCount.
            float pi = length(pi3f);
            float wi = pi * lightCount; // lightCount means invPdf
            rand = randSimple(float2(rand, pi));
            r.update(xi, wi, pi3f, rand);
            rand = randSimple(float2(rand, pi));
        }
        outputReservoir[pixel.x + screen.x * pixel.y] = r;
        return float3(0.f);
    }
    else
    {
        uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
        float invPdf = lightCount;

        AnalyticLightSample ls;
        if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls))
            return float3(0.f);
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
}
/*
 */

// raytracing main function
float3 tracePath(uint2 pixel, uint2 screen)
{
    float3 outputColor = float3(0.f);

    const float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        const bool isCurveHit = hit.getType() == HitType::Curve;
        let lod = ExplicitLodTextureSampler(0.f);

        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);

        let bsdf = gScene.materials.getBSDF(sd, lod);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        for (uint i = 0; i < gPRNGDimension; i++)
            sampleNext1D(sg);

        float3 rayOrigin = sd.computeNewRayOrigin();

        outputColor += bsdf.getProperties(sd).emission + evalDirectAnalytic(pixel, screen, sd, bsdf, sg);
    }
    else
    {
        outputColor = gScene.envMap.eval(primaryRayDir); // : kDefaultBackgroundColor;
    }
    return outputColor;
}

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    // The miss shader is executed if the ray misses all geometry. Mark as visible.
    rayData.visible = true;
}

[shader("anyhit")]
void shadowTriangleMeshAnyHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
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
    if (!kUseReSTIR)
        gOutputColor[pixel] = float4(color, 1.f);
}
