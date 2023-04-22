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
static const float prr = 0.6f;
static const float invPrr = 1.0 / prr;
static const float prrSecondry = 0.6f;
static const float invPrrSecondry = 1.0 / prrSecondry;
static const bool kUseImportanceSampling = true;
static const uint kMaxBounces = 10;
static const bool kUseEnvLight = true;
static const bool kUseEmissiveLights = true;
static const bool kUseAnalyticLights = true;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float3> gNormal;
Texture2D<float3> gPositionW;
Texture2D<float4> gNoise;
Texture2D<float4> gMotionVector;

RWStructuredBuffer<GIReservoir> gPrevFrameReservoirs;
RWStructuredBuffer<GIReservoir> gTemporalReservoirs;
RWStructuredBuffer<GISample> gInitSamples;
RWTexture2D<float3> gThroughput;

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
        break;
    case (uint)GenericLightType::Emissive:
        valid = generateEmissiveLightsSample(sd, hasReflection && !hasTransmission, ls, sampler.emmisiveSampler, sg);
        break;
    case (uint)GenericLightType::Analytic:
        valid = generateAnalyticLightsSample(sd, ls, sg);
        break;
    default:
        valid = false;
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

/**
    \param[in] ray
    \param[out] hit
    \param[out] hitT
    \return True if ray get a hit.
*/

bool traceRayInline(const Ray ray, inout HitInfo hit, inout float hitT)
{
    logTraceRay(PixelStatsRayType::ClosestHit);
    SceneRayQuery<true> srq;
    return srq.traceRay(ray, hit, hitT, RAY_FLAG_NONE, 0xff);
}

/**
    \param[in] ray
    \return True if ray get a hit.
 */

bool traceVisibilityRay(const Ray ray)
{
    logTraceRay(PixelStatsRayType::Visibility);
    SceneRayQuery<true> srq;
    return srq.traceVisibilityRay(ray, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff);
}

/** TODO: add support env light and mesh light.
    \param[in] sd
    \param[in] mi
    \param[inout] sg
    \return Estimated direct radiance from analytic light.

*/

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
        return float3(0.0f, 0.0f, 0.f);

    // Reject sample if not in the hemisphere of a BSDF lobe.
    const uint lobeTypes = mi.getLobeTypes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    const float3 n = sd.N;
    max(sd.N, sd.faceN);
    // return n;
    // const float dot = ls.dir.x * n.x + ls.dir.y * n.y + ls.dir.z * n.z;
    if (dot(ls.dir, sd.N) <= kMinCosTheta && !hasTransmission)
        return float3(0.f);
    if (dot(ls.dir, sd.N) >= -kMinCosTheta && !hasReflection)
        return float3(0.f);

    // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
    const float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);
    // computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);

    // Test visibility by tracing a shadow ray.
    Ray ray = Ray(origin, ls.dir, 0.0f, ls.distance);
    if (!traceVisibilityRay(ray))
        return float3(0.0f);

    // Evaluate contribution.
    return (mi.eval(sd, ls.dir, sg) * ls.Li * invPdf);
}

/**
    \param[in] sd
    \param[in] mi
    \param[in] rayOrigin
    \param[inout] rayData
    \return True if the sample is valid.
*/

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

/** Process a hit
    \param[in] hit
    \param[inout] rayData
    \return Whether ray still alive(true) or killed(false).
*/

bool handleHit(const HitInfo hit, inout ScatterRayData rayData)
{
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hit, rayData.origin, rayData.direction, lod);
    let mi = gScene.materials.getMaterialInstance(sd, lod);

    // eval radiance
    // if (kUseEmissiveLights)
    if (rayData.length > 0)
        rayData.radiance += rayData.throughput * (mi.getProperties(sd).emission);

    if (rayData.length >= kMaxBounces)
    {
        rayData.terminated = true;
        return false;
    }
    //
    rayData.radiance += rayData.throughput * evalDirectAnalytic(sd, mi, rayData.sg);

    // add length
    float3 rayOrigin = hit.getType() == HitType::Curve ? sd.posW - sd.curveRadius * sd.N : sd.computeNewRayOrigin();
    prepareScatterRay(sd, mi, rayOrigin, rayData);
    if (!rayData.terminated)
    {
        rayData.length++;
        return true;
    }
    else
    {
        return false;
    }
}

/** Execute Simple Pathtracing with NEE+Russian Rourette
    \param[in] rayData the payload for tracing path
    \param[in] sg Sample Generator
    \return Returns the estimated indirect radiance.
 */

void pathTrace(inout ScatterRayData rayData)
{
    for (uint depth = 0; depth <= kMaxBounces && !rayData.terminated; depth++)
    {
        Ray ray = Ray(rayData.origin, rayData.direction, 0.f, FLT_MAX);
        HitInfo hit;
        float hitT;
        if (traceRayInline(ray, hit, hitT))
        {
            handleHit(hit, rayData);
            // Russian rourette
            if (sampleNext1D(rayData.sg) > prr)
                break;
            rayData.throughput *= invPrr;
        }
        else
        {
            rayData.terminated = true;
        }
    }
}

/**
    \param[in] sd
    \param[in] mi
    \param[inout] sample
    \return
*/

enum class InitialSamplePDFType
{
    Uniform,
    CosineWeighted,
    BSDF,
}

/**
    \param[in] method
    \param[in] sd
    \param[in] isCurveHit
    \param[in] mi
    \param[inout] rayData
    \param[out] invPdf
    \return True if sucsess to generate ray payload.
*/

bool prepareInitialSampleRay(
    const InitialSamplePDFType method,
    const ShadingData sd,
    const bool isCurveHit,
    const IMaterialInstance mi,
    inout ScatterRayData rayData,
    out float invPdf
)
{
    switch (method)
    {
    case InitialSamplePDFType::Uniform:
        float3 randomDir = sample_sphere(sampleNext2D(rayData.sg));

        const uint lobeTypes = mi.getLobeTypes(sd);
        const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
        const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
        invPdf = hasReflection && hasTransmission ? M_4PI : M_2PI;
        randomDir = (dot(randomDir, sd.N) < kMinCosTheta) && hasReflection && !hasTransmission ? -randomDir : randomDir;
        randomDir = hasTransmission && !hasReflection ? -randomDir : randomDir;

        if (isCurveHit)
            rayData.origin = sd.posW - sd.curveRadius * sd.N;
        else if (hasTransmission)
            rayData.origin = sd.computeNewRayOrigin(false);
        else
            rayData.origin = sd.computeNewRayOrigin();
        rayData.direction = randomDir;
        rayData.throughput *= mi.eval(sd, randomDir, rayData.sg) * invPdf * abs(dot(randomDir, max(sd.N, sd.faceN)));
        break;
    case InitialSamplePDFType::CosineWeighted:
        // TODO implement this.
        return false;
        break;
    case InitialSamplePDFType::BSDF:
        BSDFSample result;
        if (mi.sample(sd, rayData.sg, result, true))
        {
            if (isCurveHit)
                rayData.origin = sd.posW - sd.curveRadius * sd.N;
            else if (result.isLobe(LobeType::Transmission))
                rayData.origin = sd.computeNewRayOrigin(false);
            else
                rayData.origin = sd.computeNewRayOrigin();
            rayData.direction = result.wo;
            rayData.throughput *= result.weight;
            invPdf = 1.0f / mi.evalPdf(sd, result.wo, true);
            return any(rayData.throughput > 0.f);
        }
        else
        {
            rayData.terminated = true;
            return false;
        }
        break;
    }
    return true;
}

/**
    \param[in] sd Shading Data of Xv
    \param[in] mi Material Data of Xv
    \param[in] isCurveHit
    \param[inout] sg Sample Generator
    \param[inout] radiance
    \param[inout] sample Sampled Data of Xs
    \return True if success to generate sample.
*/

float3 generateInitialSample(
    const ShadingData sd,
    const IMaterialInstance mi,
    const bool isCurveHit,
    inout SampleGenerator sg,
    inout GISample sample
)
{
    BSDFSample result;

    // Prepare secondry ray.
    ScatterRayData rayData = ScatterRayData(sg);
    float invPdf = 0.f;

    // terminatedの処理が怪しい
    prepareInitialSampleRay(InitialSamplePDFType::BSDF, sd, isCurveHit, mi, rayData, invPdf);

    // Launch ray.
    Ray ray = Ray(rayData.origin, rayData.direction, 0.f, FLT_MAX);
    HitInfo hit;
    float hitT;

    // Init ray throughput weight for spatial resampling.
    float3 throughput = rayData.throughput;
    rayData.throughput = float3(1.0f);
    if (traceRayInline(ray, hit, hitT))
    {
        // Compute Indirect radiance
        if (sampleNext1D(sg) <= prrSecondry && handleHit(hit, rayData))
        {
            rayData.throughput *= invPrrSecondry;
            pathTrace(rayData);
        }

        // Set sample.
        sample.rand = sampleNext1D(sg);
        sample.Lo = rayData.radiance;
        sample.xv = sd.posW;
        sample.nv = max(sd.N, sd.faceN);
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sampledSd = loadShadingData(hit, rayData.origin, rayData.direction, lod);
        sample.xs = sd.posW;
        sample.ns = max(sd.N, sd.faceN);
        sample.invPdf = invPdf;

        return throughput;
    }
    else
    {
        return float3(-1.0f);
    }
}

/**
    \param[in] pixel
    \param[in] s
*/

void temporalResampling(const uint2 pixel, const GISample s, inout SampleGenerator sg)
{
    // temporal reservoirsの初期化をお願いマッスル
    int2 prevPixelPos = (int2)pixel + int2(gFrameDim * gMotionVector[pixel].xy);
    int prevFramePix1D = prevPixelPos.x + (int)gFrameDim.x * prevPixelPos.y;
    GIReservoir currentReservoir = GIReservoir();
    currentReservoir.update(s, length(s.Lo) * s.invPdf, s.rand);

    if (prevFramePix1D >= 0 && prevFramePix1D < gFrameDim.x * gFrameDim.y)
    {
        ;
        let res = gPrevFrameReservoirs[prevFramePix1D];
        currentReservoir.merge(res, length(res.ps));
    }

    // TODO: clamp M
    if (currentReservoir.M > 30)
    {
        currentReservoir.wSum *= (float)30 / currentReservoir.M;
        currentReservoir.M = 30;
    }
    gTemporalReservoirs[pixel.x + gFrameDim.x * pixel.y] = currentReservoir;
}

// void temporalResampling(const uint2 pixel, const GISample s)
// {
//     int2 prevPixelPos = (int2)pixel + int2(gFrameDim * gMotionVector[pixel].xy);
//     int prevFramePix1D = prevPixelPos.x + (int)gFrameDim.x * prevPixelPos.y;
//     GIReservoir currentReservoir = GIReservoir();
//     currentReservoir.update(s, length(s.Lo) * s.invPdf, s.Lo);
//     if (prevFramePix1D >= 0 && prevFramePix1D < gFrameDim.x * gFrameDim.y)
//     {
//         let res = gPrevFrameReservoirs[prevFramePix1D];
//         uint M = currentReservoir.M + res.M;
//         float fixedW = res.wSum * (length(res.ps) / length(currentReservoir.ps));
//         currentReservoir.update(res.s, fixedW, res.ps);
//         currentReservoir.M = M;
//     }
//     // TODO: clamp M
//     if (currentReservoir.M > 30)
//     {
//         currentReservoir.wSum *= (float)30 / currentReservoir.M;
//         currentReservoir.M = 30;
//     }
//     gTemporalReservoirs[pixel.x + gFrameDim.x * pixel.y] = currentReservoir;
//     gPrevFrameReservoirs[pixel.x + gFrameDim.x * pixel.y] = currentReservoir;
// }

/** Initial Sampling
    \param[in] pixel
    \param[in] screen
 */

void sampling(uint2 pixel, uint2 screen)
{
    // uint2 noiseSeed = {(pixel.x+gFrameCount)%gNoiseTexDim.x, pixel.y%gNoiseTexDim.y};
    // float3 randVec = gNoise[noiseSeed].xyz;
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
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

        // compute Direct Lighting
        // TODO: replace ReSTIR
        if (computeDirect)
        {
            color += (mi.getProperties(sd).emission);
            color += evalDirectAnalytic(sd, mi, sg);
            // color = sd.N;
        }
        // if (false)
        // {
        //     // Simple path tracer
        //     // referenceと結果が一致するので挙動に問題なし
        //     ScatterRayData rayData = ScatterRayData(sg);
        //     prepareScatterRay(sd, mi, sd.computeNewRayOrigin(), rayData);
        //     GISample sample;
        //     pathTrace(rayData);
        //     sample.Lo = rayData.radiance;
        //     sample.invPdf = 0.f;
        //     sample.ns = float3(0.f);
        //     sample.nv = float3(0.f);
        //     sample.xs = float3(0.f);
        //     sample.xv = float3(0.f);
        //     sample.rand = 0.f;
        //     gThroughput[pixel] = float3(1.0f);
        //     gInitSamples[pixel.x + screen.x * pixel.y] = sample;
        // }
        // else
        // {

        GISample giSample;
        gThroughput[pixel] = generateInitialSample(sd, mi, hit.getType() == HitType::Curve, sg, giSample);
        temporalResampling(pixel, giSample, sg);
        gInitSamples[pixel.x + screen.x * pixel.y] = giSample;
        // }
    }
    else
    {
        // color += float3(0.0f, 0.0, 0.f);
    }
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
    sampling(pixel, gFrameDim);
}
