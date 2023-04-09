#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.Scene;
import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.EmissiveLightSamplerInterface;
import Utils.Debug.PixelDebug;

import Rendering.Utils.PixelStats;

import GIReservoir;

static const float prr = 0.25f;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float3> gNormal;
Texture2D<float3> gPositionW;
Texture2D<float4> gNoise;

RWStructuredBuffer<GISample> initSamples;
RWTexture2D<float4> gIrradiance;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
}

struct ScatterRayData
{
    float3 radiance;
    bool terminated;
    float3 throughput;
    float3 origin;
    float3 direction;
    uint length;
}

ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, const ITextureSampler lod)
{
    VertexData v = {};
    uint materialID = {};

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        v = gScene.getVertexData(triangleHit);
        materialID = gScene.getMaterialID(triangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH)
    if (hit.getType() == HitType::DisplacedTriangle)
    {
        const DisplacedTriangleHit displacedTriangleHit = hit.getDisplacedTriangleHit();
        v = gScene.getVertexData(displacedTriangleHit, -rayDir);
        materialID = gScene.getMaterialID(displacedTriangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
    if (hit.getType() == HitType::Curve)
    {
        const CurveHit curveHit = hit.getCurveHit();
        v = gScene.getVertexDataFromCurve(curveHit);
        materialID = gScene.getMaterialID(curveHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_SDF_GRID)
    if (hit.getType() == HitType::SDFGrid)
    {
        const SDFGridHit sdfGridHit = hit.getSDFGridHit();
        v = gScene.getVertexDataFromSDFGrid(sdfGridHit, rayOrigin, rayDir);
        materialID = gScene.getMaterialID(sdfGridHit.instanceID);
    }
#endif

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

bool traceRayInline(const Ray ray, out HitInfo hit, out float hitT)
{
    logTraceRay(PixelStatsRayType::ClosestHit);
    SceneRayQuery<true> srq;
    return srq.traceRay(ray, hit, hitT, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff);
}

bool traceVisibilityRay(const Ray ray)
{
    logTraceRay(PixelStatsRayType::Visibility);
    SceneRayQuery<true> srq;
    return srq.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}

float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, float4 rand, const SampleGenerator sg)
{
    AnalyticLightSample als;

    uint lightCount = gScene.lightCount;
    const uint id = min(uint(rand.x * lightCount), lightCount - 1);
    float invPdf = lightCount;

    if (!sampleLight(sd.posW, gScene.getLight(id), sg, als))
        return float3(0.f);

    float3 n = dot(sd.faceN, als.dir) >= 0.f ? sd.faceN : -sd.faceN;
    float3 origin = computeRayOrigin(sd.posW, n);
    Ray ray = Ray(origin, als.dir, 0.0f, als.distance);
    if (!traceVisibilityRay(ray))
        return float3(0.f);

    return mi.eval(sd, als.dir, sg) * als.Li * invPdf;
}

bool generateScatterRay(
    const ShadingData sd,
    const IMaterialInstance mi,
    const float3 rayOrigin,
    inout ScatterRayData rayData,
    const float p,
    const float u
)
{
    if (u > p)
    {
        rayData.terminated = true;
        return false;
    }
    BSDFSample bsdfSample;
    if (mi.sample(sd, rayData.sg, bsdfSample, kUseImportanceSampling))
    {
        rayData.origin = rayOrigin;
        if (bsdfSample.isLobe(LobeType::Transmission))
        {
            rayData.origin = sd.computeNewRayOrigin(false);
        }
        rayData.direction = bsdfSample.wo;
        rayData.throughput *= bsdfSample.weight;
        return any(rayData.throughput > 0.f);
    }

    return false;
}

float pathTrace(ShadingData sd, SampleGenerator sg)
{
    AnalyticLightSample als;
}

void sampling(uint2 pixel)
{
    // uint2 noiseSeed = {(pixel.x+gFrameCount)%gNoiseTexDim.x, pixel.y%gNoiseTexDim.y};
    // float3 randVec = gNoise[noiseSeed].xyz;
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
    float3 randVec = sampleNext3D(sg);
    randVec = dot(gNormal[pixel].xyz, randVec) > 0 ? randVec : -randVec;

    // {
    //     const float3 primaryRayOrigin = gScene.camera.getPosition();
    //     const float3 primaryRayDir = gScene.camera.computeRayPinhole(pixel, gFrameDim).dir;
    //     const HitInfo hit = HitInfo(gVBuffer[pixel]);
    //     if (hit.isValid())
    //     {
    //         let lod = ExplicitLodTextureSampler(0.f);
    //         ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
    //         gIrradiance[pixel] = float4(evalDirectIrradiance(sd, float4(randVec.x, randVec.y, randVec.z, 1.0f), sg), 1.0f);

    //     }
    // }

    {
        HitInfo hit;
        float hitT;
        float3 rayOrigin = computeRayOrigin(gPositionW[pixel], gNormal[pixel]);
        Ray ray = Ray(rayOrigin, randVec, 0.f, FLT_MAX);
        if (traceRayInline(ray, hit, hitT))
        {
            let lod = ExplicitLodTextureSampler(0.f);
            ShadingData sd = loadShadingData(hit, rayOrigin, randVec, lod);
            // gScene.camera.data.
            // gIrradiance[pixel] = float4(evalDirectIrradiance(sd, float4(randVec.x,randVec.y,randVec.z, 1.0f), sg),1.0f);
        }
    }
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
    sampling(pixel);
}
