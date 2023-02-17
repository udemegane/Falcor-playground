#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
import Rendering.Utils.PixelStats;
import Rendering.Lights.LightHelpers;
import LoadShadingData;

// Input
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;

// Output
RWTexture2D<float4> gShadingColor;
RWTexture2D<float4> gOutColor;
RWTexture2D<float> gShadow;

static const uint risSamples = RIS_SAMPLES;
static const bool useTemporalReuse = USE_TEMPORAL_REUSE;
static const float kRayMax = FLT_MAX;

struct MonoReservoir
{
    float wSum;
    uint currentSampleId;
    float targetPdfSample;
    uint M;
    __init()
    {
        wSum = 0;
        M = 0;
        currentSampleId = 0;
        targetPdfSample = 0.f;
    }
    [mutating]
    bool update(const uint xi, const float wi, const float pi, const float rand)
    {
        wSum += wi;
        bool accept = rand <= wi / wSum;
        if (accept || M == 0)
        {
            currentSampleId = xi;

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

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint2 gFrameDim;
}

struct ShadowRayData
{
    bool visible;
}

float3 getPrimaryRayDir(uint2 pixel, uint2 screen, const Camera camera)
{
    if (true)
    {
        return -gViewW[pixel].xyz;
    }
    else
    {
        return camera.computeRayPinhole(pixel, screen).dir;
    }
}

float randSimple(float2 p)
{
    return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

bool traceVisibilityRay(const Ray ray)
{
    logTraceRay(PixelStatsRayType::Visibility);
    SceneRayQuery<true> srq;
    return srq.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}

float evalShadow(const uint2 pixel, const uint2 screen, const ShadingData sd, const IBSDF bsdf, SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return 1.f;
    MonoReservoir r = MonoReservoir();
    float2 seed = sampleNext2D(sg);
    float rand = randSimple(seed);
    for (uint i = 0; i < risSamples; i++)
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
        r.update(xi, wi, pi, rand);
        rand = randSimple(float2(rand, pi));
    }
    if (useTemporalReuse)
    {
    }
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(r.currentSampleId), sg, ls))
        return 1.f;
    float3 n = dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN;
    float3 origin = computeRayOrigin(sd.posW, n);
    Ray ray = Ray(origin, ls.dir, 0.0f, ls.distance);
    if (!traceVisibilityRay(ray))
        return 0.f;
    else
        return 1.f;
}

float calcShadow(uint2 pixel, uint2 screen)
{
    float out = 1.f;
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

        float3 rayOrigin = sd.computeNewRayOrigin();

        out = evalShadow(pixel, screen, sd, bsdf, sg);
    }

    return out;
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    gShadow[pixel] = calcShadow(pixel, gFrameDim);
}
