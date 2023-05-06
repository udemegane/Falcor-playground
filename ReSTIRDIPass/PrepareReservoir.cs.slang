#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.Scene;
import Utils.Attributes;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;

import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.LightHelpers;

import RenderPasses.ReSTIRDIPass.Reservoir;
import RenderPasses.ReSTIRDIPass.LoadShadingData;
import RenderPasses.ReSTIRDIPass.Params;
import RenderPasses.ReSTIRDIPass.StaticParams;

// #define is_valid(name) (is_valid_##name != 0)

RWStructuredBuffer<PackedReservoir> gTemporalReservoir;
RWStructuredBuffer<PackedReservoir> gIntermediateReservoir;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float> gDepth;
Texture2D<float4> gViewW;
Texture2D<float2> gMotionVector;
ParameterBlock<Params> params;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    bool isValidViewW;
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
    float invPdf;
    float3 origin;
    float distance;
    float3 dir;
}

float3 getPrimaryRayDir(uint2 pixel, uint2 screen, const Camera camera)
{
    if (isValidViewW)
    {
        return -gViewW[pixel].xyz;
    }
    else
    {
        return camera.computeRayPinhole(pixel, screen).dir;
    }
}

int2 getPrevPixel(float3 pos, Camera camera)
{
    float4 prevClip = mul(camera.data.prevViewProjMatNoJitter, float4(pos, 1.0));
    float2 prevUV = float2(((prevClip.x) / (prevClip.w)) * 0.5 + 0.5, ((-prevClip.y) / (prevClip.w)) * 0.5 + 0.5);
    int2 prevPix = int2(prevUV.x * (float)gFrameDim.x, prevUV.y * (float)gFrameDim.y);
    return prevPix;
}

bool selectLightType(out uint lightType, out float pdf, float rand)
{
    float p[3];

    p[0] = kUseEnvLight ? 1.f : 0.f;
    p[1] = kUseEmissiveLights ? 1.f : 0.f;
    p[2] = kUseAnalyticLights ? 3.f : 0.f;

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

bool generateAnalyticLightsSample<S : ISampleGenerator>(const ShadingData sd, inout LightSample ls, inout S sg)
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
    ls.Li = als.Li;
    // ls.Li = als.Li * invPdf;
    ls.invPdf = invPdf;
    // ls.invPdf = invPdf / (als.pdf + DBL_EPSILON);
    ls.origin = computeRayOrigin(sd.posW, dot(sd.faceN, als.dir) >= 0.f ? sd.faceN : -sd.faceN);
    ls.distance = als.distance;
    ls.dir = als.dir;
    // ls.lightType = (uint)GenericLightType::Analytic;
    // ls.id = lightIndex;

    return any(ls.Li > 0.f);
}

bool generateEmissiveLightsSample<S : ISampleGenerator>(const ShadingData sd, const bool upperHemisphere, inout LightSample ls, inout S sg)
{
    ls = {};
    if (!kUseEmissiveLights)
        return false;
    TriangleLightSample tls;
    if (!params.emissiveSampler.sampleLight(sd.posW, sd.N, upperHemisphere, sg, tls))
        return false;

    ls.Li = tls.pdf > 0.f ? tls.Le / tls.pdf : float3(0.f);
    ls.invPdf = 1.0f / (tls.pdf + DBL_EPSILON);
    ls.origin = computeRayOrigin(sd.posW, dot(sd.faceN, tls.dir) >= 0.f ? sd.faceN : -sd.faceN);
    float3 toLight = tls.posW - sd.posW;
    ls.distance = length(toLight);
    ls.dir = normalize(toLight);
    // ls.lightType = (uint)GenericLightType::Emissive;
    // ls.id = tls.triangleIndex;

    return any(ls.Li > 0.f);
}

bool generateEnvLightSample<S : ISampleGenerator>(const ShadingData sd, inout LightSample ls, inout S sg)
{
    ls = {};
    if (!kUseEnvLight)
        return false;
    EnvMapSample lightSample;
    if (!params.envMapSampler.sample(sampleNext2D(sg), lightSample))
        return false;
    ls.Li = lightSample.pdf > 0.f ? lightSample.Le / lightSample.pdf : float3(0.f);
    ls.invPdf = 1.0f / lightSample.pdf;
    ls.origin = computeRayOrigin(sd.posW, dot(sd.faceN, lightSample.dir) >= 0.f ? sd.faceN : -sd.faceN);
    ls.dir = lightSample.dir;
    ls.distance = FLT_MAX;
    // ls.lightType = (uint)GenericLightType::EnvMap;

    return any(ls.Li > 0.f);
}

bool generateLightSample<S : ISampleGenerator>(const ShadingData sd, const uint lobeTypes, inout LightSample ls, inout S sg)
{
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
        valid = generateEnvLightSample(sd, ls, sg);
        break;
    case (uint)GenericLightType::Emissive:
        valid = generateEmissiveLightsSample(sd, hasReflection && !hasTransmission, ls, sg);
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
        // ls.lightType = lightType;
        ls.invPdf /= selectionPdf;
        ls.Li /= selectionPdf;

        return true;
    }
    else
    {
        return false;
    }
}

Reservoir wrs<S : ISampleGenerator>(const ShadingData sd, const IMaterialInstance mi, inout S sg)
{
    Reservoir r = Reservoir();
    const uint lightCount = gScene.getLightCount();

    [unroll]
    for (uint i = 0; i < kRISSampleNums; i++)
    {
        if (kUseAllLightSource)
        {
            // This is still broken yet.
            // TODO: Fix incorrect emissive and envmap pdf.
            LightSample ls;
            const uint lobeTypes = mi.getLobeTypes(sd);
            float3 Li = DBL_EPSILON;

            if (generateLightSample(sd, lobeTypes, ls, sg))
                Li = ls.Li;
            Sample s = Sample();
            s.Li = Li;
            s.dir = ls.dir;
            s.length = ls.distance;
            float pi = luminance(mi.eval(sd, ls.dir, sg) * Li);
            float wi = pi * ls.invPdf;
            r.update(s, wi, pi, sampleNext1D(sg));
        }
        else
        {
            const uint xi = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
            AnalyticLightSample ls;
            float3 Li = DBL_EPSILON;
            if (sampleLight(sd.posW, gScene.getLight(xi), sg, ls))
                Li = ls.Li;
            Sample s = Sample();
            s.Li = Li;
            s.dir = ls.dir;
            s.length = ls.distance;
            float pi = luminance(mi.eval(sd, ls.dir, sg) * Li);
            float wi = pi * lightCount;
            r.update(s, wi, pi, sampleNext1D(sg));
        }
    }
    return r;
}

void temporalResampling<S : ISampleGenerator>(const uint2 pixel, const float3 pos, inout Reservoir current, inout S sg)
{
    int2 prevPix;
    if (kUseMotionVector)
        prevPix = (int2)pixel + int2(gFrameDim * gMotionVector[pixel].xy);
    else
        prevPix = getPrevPixel(pos, gScene.camera);
    int prevFramePix1D = prevPix.x + (int)gFrameDim.x * prevPix.y;

    if (false && prevPix.x >= 0 && prevPix.y >= 0 && prevPix.x < gFrameDim.x && prevPix.y < gFrameDim.y)
    {
        bool filter = true;
        if (filter)
        {
            Reservoir prevR = Reservoir.unpack(gTemporalReservoir[prevFramePix1D]);
            current.merge(prevR, sampleNext1D(sg));
            if (current.M > kTemporalMax)
            {
                current.wSum *= (float)kTemporalMax / current.M;
                current.M = kTemporalMax;
            }
        }
    }
    gIntermediateReservoir[pixel.x + gFrameDim.x * pixel.y] = current.pack();
}

void sampling(uint2 pixel, uint2 screen)
{
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
    float3 color = float3(0.f);
    float3 primaryRayOrigin = gScene.camera.getPosition();
    float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const HitInfo hit = HitInfo(gVBuffer[pixel]);

    if (hit.isValid())
    {
        const bool isCurveHit = hit.getType() == HitType::Curve;
        let lod = ExplicitLodTextureSampler(0.f);

        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);

        let mi = gScene.materials.getMaterialInstance(sd, lod);
        Reservoir r = wrs(sd, mi, sg);
        temporalResampling(pixel, sd.posW, r, sg);
    }
    else
    {
        Reservoir r = Reservoir();
        Sample s = Sample();
        s.dir = normalize(primaryRayDir);
        s.length = kRayMax;
        s.Li = kUseEnvLight ? gScene.envMap.eval(primaryRayDir) : float3(0.0f);
        r.update(s, HLF_EPSILON, HLF_EPSILON, 0.0f);
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
