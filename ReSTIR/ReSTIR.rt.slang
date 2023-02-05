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

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint gPRNGDimension;
}

struct RISReservoir<S>
{
    float wSum;
    S currentSample;
    float targetPdfSample;
    uint M;
    __init(const S sample)
    {
        wSum = 0;
        M = 0;
        currentSample = sample;
        // pTarget = float3(0.f);
        targetPdfSample = 0.f;
    }
    [mutating]
    bool update(const S xi, const float wi, const float pi, const float rand)
    {
        wSum += wi;
        // M += (uint)step(pi, 0.00001);
        bool accept = rand <= wi / wSum;
        if (accept || M == 0)
        {
            currentSample = xi;

            targetPdfSample = pi;
        }
        M++;
        return accept;
    }

    float getInvPDF()
    {
        return wSum / (M * targetPdfSample);
    }
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;

RWStructuredBuffer<RISReservoir<uint>> prevFrameReservoir;

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
static const bool kUseSpatialReuse = USE_SPATIAL_REUSE;
static const uint kSpatialNeigborsNum = 5;
static const float kSampleRadius = 30.0;

float randSimple(float2 p)
{
    return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// shadow ray strcuture
struct ShadowRayData
{
    bool visible;
}

RISReservoir<S> combineReservoir<S>(const RISReservoir<S> ra, const RISReservoir<S> rb)
{
    RISReservoir<S> res;
    // uint M = 0;
    res.update(ra.currentSample, ra.wSum, ra.targetPdfSample, randSimple((ra.wSum, ra.targetPdfSample)));
    // M += ra.M;
    res.update(rb.currentSample, rb.wSum, rb.targetPdfSample, randSimple((rb.wSum, rb.targetPdfSample)));
    // M += rb.M;
    res.M = ra.M + rb.M;
    return res;
}

int getPrevFramePos1D(uint2 pixelPos, uint2 screen)
{
    uint2 prevPixPos = pixelPos + screen * gMVec[pixelPos];
    return prevPixPos.x + screen.x * prevPixPos.y;
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

ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, const ITextureSampler lod)
{
    VertexData vertexData = {};
    uint materialID = {};

// プリプロセッサかますと補完が壊れる
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit th = hit.getTriangleHit();
        vertexData = gScene.getVertexData(th);
        materialID = gScene.getMaterialID(th.instanceID);
    }
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH)
    if (hit.getType() == HitType::DisplacedTriangle)
    {
        const DisplacedTriangleHit dth = hit.getDisplacedTriangleHit();
        vertexData = gScene.getVertexData(dth, -rayDir);
        materialID = gScene.getMaterialID(dth.instanceID);
    }
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
    if (hit.getType() == HitType::Curve)
    {
        const CurveHit ch = hit.getCurveHit();
        vertexData = gScene.getVertexDataFromCurve(ch);
        materialID = gScene.getMaterialID(ch.instanceID);
    }
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_SDF_GRID)
    if (hit.getType() == HitType::SDFGrid)
    {
        const SDFGridHit sh = hit.getSDFGridHit();
        vertexData = gScene.getVertexDataFromSDFGrid(sh, rayOrigin, rayDir);
        materialID = gScene.getMaterialID(sh.instanceID);
    }
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CUSTOM)
    {
    }
#endif
    ShadingData sd = gScene.materials.prepareShadingData(vertexData, materialID, -rayDir, lod);
    return sd;
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
    uint lightIndex = 0;
    float3 invPdf = float3(0.f);
    if (kUseReSTIR)
    {

        RISReservoir<uint> r = RISReservoir<uint>(lightIndex);
        for (uint i = 0; i < kRISSampleNums; i++)
        {
            float2 rand = sampleNext2D(sg);
            // Sample LightID from uniform distribution
            const uint xi = min(uint(rand.x * lightCount), lightCount - 1);

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
            r.update(xi, wi, pi, rand.y);
        }
        // if (kUseSpatialReuse)
        // {
        //     float rand = sampleNext1D(sg);
        //     for (uint i = 0; i < kSpatialNeigborsNum; i++)
        //     {
        //         float radius = kSampleRadius * rand;
        //         float angle = 2.0f * M_PI * frac(sin(gFrameCount * rand));
        //         uint2 neighborPos = {
        //             pixel.x + uint(radius * cos(angle)),
        //             pixel.y + uint(radius * sin(angle))
        //         };

        //         rand = randSimple(((float)neighborPos.x / rand, (float)neighborPos.y / rand));
        //     }
        //     // TODO: Combine Neighbor reservoirs.
        // }

        if (kUseTemporalReuse)
        {
            RISReservoir<uint> rprev = prevFrameReservoir[getPrevFramePos1D(pixel, screen)];
            if (rprev.M > r.M * kTemporalReuseMaxM)
            {
                float ratio = ((float)kTemporalReuseMaxM * r.M / rprev.M);
                rprev.wSum *= ratio;
                rprev.M = kTemporalReuseMaxM * r.M;
            }
            RISReservoir<uint> res = RISReservoir<uint>(0);
            res.update(r.currentSample, r.wSum, r.targetPdfSample, randSimple((r.wSum, rprev.targetPdfSample)));
            res.update(rprev.currentSample, rprev.wSum, rprev.targetPdfSample, randSimple((rprev.wSum, r.targetPdfSample)));
            res.M = r.M + rprev.M; // clamp(rprev.M, 0, r.M * 20);
            // r.wSum = r.wSum + rprev.wSum * 0.000001 + res.wSum * 0.000001; // コンパイラだます
            r = res;
            // r = combineReservoir<uint>(r, prevFrameReservoir[ppos]);
        }
        prevFrameReservoir[pixel.x + screen.x * pixel.y] = r; // for next frame;
        lightIndex = r.currentSample;
        invPdf = r.getInvPDF();
    }
    else
    {
        lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
        invPdf = lightCount;
    }
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
        // curve primitive消した

        outputColor += bsdf.getProperties(sd).emission + evalDirectAnalytic(pixel, screen, sd, bsdf, sg);

        // ScatterRayData rayData = ScatterRayData(sg);
        // generateScatterRay(sd, bsdf, rayOrigin, rayData);
        // outputColor += evalScatterRayAll(rayData);
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

    gOutputColor[pixel] = float4(color, 1.f);
}
