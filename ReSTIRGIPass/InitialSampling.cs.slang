#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.Scene;
import Scene.Shading;
import Scene.Material.ShadingUtils;
import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;

import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.LightHelpers;

import Utils.Debug.PixelDebug;

import Rendering.Utils.PixelStats;

import GIReservoir;

// あとでマジックナンバーやめる
static const float prr = 0.7f;
static const float invPrr = 1.0 / prr;
static const bool kUseImportanceSampling = true;
static const uint kMaxBounces = 10;
static const bool kUseEnvLight = true;
static const bool kUseEmissiveLights = true;
static const bool kUseAnalyticLights = true;

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

    SampleGenerator sg;
    __init(SampleGenerator sg)
    {
        this.terminated = false;
        this.length = 0;
        this.radiance = float3(0.f);
        this.throughput = float3(1.0f);
        this.origin = float3(0.f);
        this.direction = float3(0.f);
        this.sg = sg;
    }
}

enum class GenericLightType
{
    EnvMap,
    Emissive,
    Analytic
}
struct LightSample
{
    float3 Li;
    float pdf;
    float3 origin;
    float distance;
    float3 dir;
    uint lightType;
}

struct LightSampler
{
    EmissiveLightSampler emmisiveSampler;
    EnvMapSampler envmapSampler;
    __init()
    {
        EmissiveLightSampler emissiveSampler;
        EnvMapSampler envmapSampler;
        this.emmisiveSampler = emissiveSampler;
        this.envmapSampler = envmapSampler;
    }
}

bool selectLightType(out uint lightType, out float pdf, float rand)
{
    float p[3];

    p[0] = kUseEnvLight ? 1.f : 0.f;
    p[1] = kUseEmissiveLights ? 1.f : 0.f;
    p[2] = kUseAnalyticLights ? 1.f : 0.f;

    float sum = p[0] + p[1] + p[2];
    if (sum != 0.f)
    {
        float invSum = 1.f / sum;
        p[0] *= invSum;
        p[1] *= invSum;
        p[2] *= invSum;
    }

    [unroll]
    for (lightType = 0; lightType < 3; ++lightType)
    {
        if (rand < p[lightType])
        {
            pdf = p[lightType];
            return true;
        }
        rand -= p[lightType];
    }
    return false;
}

bool generateAnalyticLightsSample(const ShadingData sd, inout LightSample ls, inout SampleGenerator sg)
{
    ls = {};
    uint lightCount = gScene.getLightCount();
    if (!kUseAnalyticLights || lightCount == 0)
        return false;
    uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    float invPdf = lightCount;
    AnalyticLightSample als;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, als))
        return false;
    ls.Li = als.Li * invPdf;
    ls.pdf = als.pdf / invPdf;
    ls.origin = computeRayOrigin(sd.posW, dot(sd.faceN, als.dir) >= 0.f ? sd.faceN : -sd.faceN);
    ls.distance = als.distance;
    ls.dir = als.dir;

    return any(ls.Li > 0.f);
}

bool generateEmissiveLightsSample(
    const ShadingData sd,
    const bool upperHemisphere,
    inout LightSample ls,
    inout EmissiveLightSampler sampler,
    inout SampleGenerator sg
)
{
    ls = {};
    if (!kUseEmissiveLights)
        return false;
    TriangleLightSample tls;
    if (!sampler.sampleLight(sd.posW, sd.N, upperHemisphere, sg, tls))
        return false;
    ls.Li = tls.pdf > 0.f ? tls.Le / tls.pdf : float3(0.f);
    ls.pdf = tls.pdf;
    ls.origin = computeRayOrigin(sd.posW, dot(sd.faceN, tls.dir) >= 0.f ? sd.faceN : -sd.faceN);
    float3 toLight = tls.posW - sd.posW;
    ls.distance = length(toLight);
    ls.dir = normalize(toLight);

    return any(ls.Li > 0.f);
}

bool generateEnvLightSample(const ShadingData sd, inout LightSample ls, inout EnvMapSampler sampler, inout SampleGenerator sg)
{
    ls = {};
    if (!kUseEnvLight)
        return false;
    EnvMapSample lightSample;
    if (!sampler.sample(sampleNext2D(sg), lightSample))
        return false;
    ls.Li = lightSample.pdf > 0.f ? lightSample.Le / lightSample.pdf : float3(0.f);
    ls.pdf = lightSample.pdf;
    ls.origin = computeRayOrigin(sd.posW, dot(sd.faceN, lightSample.dir) >= 0.f ? sd.faceN : -sd.faceN);
    ls.dir = lightSample.dir;
    ls.distance = FLT_MAX;

    return any(ls.Li > 0.f);
}

bool generateLightSample(
    const ShadingData sd,
    const uint lobeTypes,
    inout LightSample ls,
    inout LightSampler sampler,
    inout SampleGenerator sg
)
{
    LightSample ls = {};
    uint lightType;
    float selectionPdf;
    if (!selectLightType(lightType, selectionPdf, sampleNext1D(sg)))
        return false;

    bool valid = false;
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);

    switch (lightType)
    {
    case (uint)GenericLightType::EnvMap:
        valid = generateEnvLightSample(sd, ls, sampler.envmapSampler, sg);
    case (uint)GenericLightType::Emissive:
        valid = generateEmissiveLightsSample(sd, hasReflection && !hasTransmission, ls, sampler.emmisiveSampler, sg);
    case (uint)GenericLightType::Analytic:
        valid = generateAnalyticLightsSample(sd, ls, sg);
    }

    if (valid)
    {
        // Reject Sample when light come from lower-hemisphere to Non-Tranclucent-material
        if (dot(ls.dir, max(sd.N, sd.faceN)) <= kMinCosTheta && !hasTransmission)
            return false;
        // Reject Sample when light come from upper-hemisphere to Non-reflective material
        if (dot(ls.dir, max(sd.N, sd.faceN)) >= -kMinCosTheta && !hasReflection)
            return false;
        ls.lightType = lightType;
        ls.pdf *= selectionPdf;
        ls.Li /= selectionPdf;

        return true;
    }
    else
    {
        return false;
    }
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

float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return float3(0.f);

    // Pick one of the analytic light sources randomly with equal probability.
    const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    float invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.

    // Sample local light source.
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls))
        return float3(0.f);

    // Reject sample if not in the hemisphere of a BSDF lobe.
    const uint lobeTypes = mi.getLobeTypes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    if (dot(ls.dir, sd.N) <= kMinCosTheta && !hasTransmission)
        return float3(0.f);
    if (dot(ls.dir, sd.N) >= -kMinCosTheta && !hasReflection)
        return float3(0.f);

    // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
    const float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);

    // Test visibility by tracing a shadow ray.
    Ray ray = Ray(origin, ls.dir, 0.0f, ls.distance);
    if (!traceVisibilityRay(ray))
        return float3(0.f);

    // Evaluate contribution.
    return mi.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

// float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
// {
//     AnalyticLightSample als;

//     uint lightCount = gScene.lightCount;
//     const float u = sampleNext1D(sg);
//     const uint id = min(uint(u * lightCount), lightCount - 1);
//     float invPdf = lightCount;

//     if (!sampleLight(sd.posW, gScene.getLight(id), sg, als))
//         return float3(0.f);

//     const uint lobeTypes = mi.getLobeTypes(sd);
//     const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
//     const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);

//     // //
//     // if (dot(als.dir, sd.N) <= kMinCosTheta && !hasTransmission)
//     //     return float3(0.f);
//     // //
//     // if (dot(als.dir, sd.N) >= -kMinCosTheta && !hasReflection)
//     //     return float3(0.f);

//     float3 n = dot(sd.faceN, als.dir) >= 0.f ? sd.faceN : -sd.faceN;
//     float3 origin = computeRayOrigin(sd.posW, n);
//     Ray ray = Ray(origin, als.dir, 0.0f, als.distance);
//     // if (!traceVisibilityRay(ray))
//     //     return float3(0.f);

//     return mi.eval(sd, als.dir, sg) * als.Li * invPdf;
// }

bool prepareScatterRay(const ShadingData sd, const IMaterialInstance mi, const float3 rayOrigin, inout ScatterRayData rayData, )
{
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
    else
    {
        rayData.terminated = true;
        return false;
    }
}

bool handleHit(const HitInfo hit, inout ScatterRayData rayData)
{
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hit, rayData.origin, rayData.direction, lod);
    let mi = gScene.materials.getMaterialInstance(sd, lod);
    float3 rayOrigin;

    // eval radiance
    rayData.radiance += rayData.throughput * (mi.getProperties(sd).emission);
    if (rayData.length >= kMaxBounces)
    {
        rayData.terminated = true;
        return false;
    }
    //
    rayData.radiance += rayData.throughput * evalDirectAnalytic(sd, mi, rayData.sg);

    // add length
    rayOrigin = sd.computeNewRayOrigin();
    prepareScatterRay(sd, mi, rayOrigin, rayData);
    if (rayData.terminated == false)
    {
        rayData.length++;
        return true;
    }
    else
    {
        return false;
    }
}

float3 pathTrace(const ShadingData sd, ScatterRayData rayData, inout SampleGenerator sg)
{
    for (uint depth = 0; depth <= kMaxBounces && !rayData.terminated; depth++)
    {
        Ray ray = Ray(rayData.origin, rayData.direction, 0.f, FLT_MAX);
        HitInfo hit;
        float hitT;
        if (traceRayInline(ray, hit, hitT))
        {
            handleHit(hit, rayData);
            if (sampleNext1D(sg) > prr)
            {
                break;
            }
            rayData.throughput *= invPrr;
        }
        else
        {
            rayData.terminated = true;
        }
    }
    return rayData.radiance;
}

// float3 evalDirect()
// {
//     AnalyticLightSample als;
// }

void sampling(uint2 pixel, uint2 screen)
{
    // uint2 noiseSeed = {(pixel.x+gFrameCount)%gNoiseTexDim.x, pixel.y%gNoiseTexDim.y};
    // float3 randVec = gNoise[noiseSeed].xyz;
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
    float3 randVec = sampleNext3D(sg);
    randVec = dot(gNormal[pixel].xyz, randVec) > 0 ? randVec : -randVec;
    float3 color = float3(0.f);
    const bool computeDirect = false;

    float3 primaryRayDir = gScene.camera.computeRayPinhole(pixel, screen, false).dir;
    float3 primaryRayOrigin = gScene.camera.getPosition();
    const HitInfo hit = HitInfo(gVBuffer[pixel]);

    if (hit.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod);
        if (computeDirect)
            color += evalDirectAnalytic(sd, mi, sg);
        ScatterRayData rayData = ScatterRayData(sg);
        if (prepareScatterRay(sd, mi, sd.computeNewRayOrigin(), rayData))
        {
            color += pathTrace(sd, rayData, sg);
        }
    }

    // compute Indirect Lignting

    if (false)
    {
        HitInfo hit;
        float hitT;
        float3 rayOriginFromPix = computeRayOrigin(gPositionW[pixel], gNormal[pixel]);
        Ray ray = Ray(rayOriginFromPix, randVec, 0.f, FLT_MAX);
        // サンプルポイントからの情報とは別に初期ヒットポイントの処理も書こうね
        // Handle Sample-Point
        if (traceRayInline(ray, hit, hitT))
        {
            let lod = ExplicitLodTextureSampler(0.f);
            ShadingData sd = loadShadingData(hit, rayOriginFromPix, randVec, lod);
            let mi = gScene.materials.getMaterialInstance(sd, lod);

            // eval indirect lighting
            ScatterRayData rayData = ScatterRayData(sg);
            bool isValidSample = prepareScatterRay(sd, mi, sd.computeNewRayOrigin(), rayData);
            color = pathTrace(sd, rayData, sg); // float4(isValidSample ?  : float3(0.f), 1.0f);
        }
    }
    gIrradiance[pixel] = float4(color, 1.0f);
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
    sampling(pixel, gFrameDim);
}
