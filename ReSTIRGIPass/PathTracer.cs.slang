#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Geometry.GeometryHelpers;
import Utils.Debug.PixelDebug;

import Scene.Shading;
import Scene.Material.ShadingUtils;

import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.LightHelpers;

import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;

RWTexture2D<float4> gOutColor;

#define is_valid(name) (is_valid_##name != 0)
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint2 gFrameDim;
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
// class CustomSampler{
//     SampleGenerator sg;
//     Texture2D<float4> noiseTex;
//     bool useTexture;
//     void register<T>(T resource){
// s
//     }
//     __init(const bool useTexture, inout SampleGenerator sg, inout Texture2D<float4> noise){
//         this.sg = sg;
//         this.useTexture = useTexture;
//         if(useTexture){
//             noiseTex=noise;
//         }
//     }

//     float next1D(){
//         if(useTexture)
//             return sampleNext1D(sg);
//     }
// }

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

bool generateLightSample(const ShadingData sd, inout LightSample ls, inout LightSampler sampler, inout SampleGenerator sg)
{
    LightSample ls = {};
    uint lightType;
    float selectionPdf;
    if (!selectLightType(lightType, selectionPdf, sampleNext1D(sg)))
        return false;

    bool valid = false;

    switch (lightType)
    {
    case (uint)GenericLightType::EnvMap:
        valid = generateEmissiveLightsSample(sd, ls, sg);
    case (uint)GenericLightType::Emissive:
        valid = generateEmissiveLightsSample(sd, ls, sampler.emmisiveSampler, sg);
    case (uint)GenericLightType::Analytic:
        valid = generateAnalyticLightsSample(sd, ls, sampler.envmapSampler, sg);
    }

    if (!valid)
        return false;
    else
    {
        ls.lightType = lightType;
        ls.pdf *= selectionPdf;
        ls.Li /= selectionPdf;

        return true;
    }
}

float3 tracePath(uint2 pixel, uint2 screen)
{
    float3 outColor = float3(0.f);
    const float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const HitInfo hit = HitInfo(gVBuffer[pixel]);

    if (hit.isValid())
    {
        LightSampler sampler = LightSampler();
        let lod = ExplicitLodTextureSampler(0.f);

        ShadingData sd;
        // let bsdf = //
    }
    else
    {
    }
    return outColor;
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    gOutColor[pixel] = (tracePath(pixel, gFrameDim), 1.0f);
}
