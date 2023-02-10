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
import Reservoir;
import RaytraceUtils;

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint2 gScreen;
}

// Input
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;
StructuredBuffer<RISReservoir> intermediateReservoir;
// InOut
RWStructuredBuffer<RISReservoir> prevFrameReservoir;
// Output
RWTexture2D<float4> gOutputColor;

#define is_valid(name) (is_valid_##name != 0)

static const uint kSpatialNeigborsNum = 5;
static const float kSampleRadius = 5.0;
static const bool kUseReSTIR = USE_RESTIR;
static const bool kUseTemporalReuse = USE_TEMPORAL_REUSE;
static const uint kTemporalReuseMaxM = TEMPORAL_REUSE_MAX_M;
static const bool kUseAutoSetMaxM = USE_AUTO_SET_MAX_M;
static const bool kUseSpatialReuse = USE_SPATIAL_REUSE;

int getPrevFramePos1D(uint2 pixelPos, uint2 screen)
{
    uint2 prevPixPos = pixelPos + uint2(screen * gMVec[pixelPos]);
    return prevPixPos.x + screen.x * prevPixPos.y;
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

void finalShading(uint2 pixel, uint2 screen)
{
    float3 outColor = float3(0.f);
    const float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let bsdf = gScene.materials.getBSDF(sd, lod);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);

        float3 rayOrigin = sd.computeNewRayOrigin();
        // curve primitive消した

        outColor += bsdf.getProperties(sd).emission + spatioTemporalTrace(pixel, screen, sd, bsdf, sg);
    }

    gOutputColor[pixel] = float4(outColor, 1.0f);
}

float3 spatioTemporalTrace(uint2 pixel, uint2 screen, ShadingData sd, IBSDF bsdf, SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    RISReservoir r = intermediateReservoir[pixel.x + gScreen.x * pixel.y];
    float rand = randSimple((r.targetPdfSample.x, r.targetPdfSample.z));
    if (kUseTemporalReuse)
    {
        RISReservoir rprev = prevFrameReservoir[getPrevFramePos1D(pixel, gScreen)];

        // clamp previous frame reservoir length.
        uint max = kUseAutoSetMaxM ? lightCount / 4 : kTemporalReuseMaxM;
        if (rprev.M > r.M * max)
        {
            float ratio = ((float)max * r.M / rprev.M);
            rprev.wSum *= ratio;
            rprev.M = max * r.M;
        }
        RISReservoir res = RISReservoir();
        res.update(r.currentSampleId, r.wSum, r.targetPdfSample, randSimple((r.wSum, rprev.targetPdfSample.x)));
        res.update(rprev.currentSampleId, rprev.wSum, rprev.targetPdfSample, randSimple((rprev.wSum, r.targetPdfSample.y)));
        res.M = r.M + rprev.M;
        r = res;
    }

    if (kUseSpatialReuse)
    {
        RISReservoir res = RISReservoir();
        res.update(r.currentSampleId, r.wSum, r.currentSampleId, rand);
        uint M = r.M;
        for (uint i = 0; i < kSpatialNeigborsNum; i++)
        {
            float radius = kSampleRadius * rand;
            float angle = 2.0f * M_PI * frac(sin(gFrameCount * rand));
            uint2 neighborPos = {
                clamp(pixel.x + uint(radius * cos(angle)), 0, screen.x),
                clamp(pixel.y + uint(radius * sin(angle)), 0, screen.y)
            };

            RISReservoir rn = intermediateReservoir[neighborPos.x + screen.x * neighborPos.y];
            float3 pi3f = float3(0.0000001f);
            AnalyticLightSample ls;
            if (sampleLight(sd.posW, gScene.getLight(rn.currentSampleId), sg, ls))
                pi3f = bsdf.eval(sd, ls.dir, sg) * ls.Li;
            float fixedW = rn.wSum * length(pi3f) / length(rn.targetPdfSample);
            res.update(rn.currentSampleId, fixedW, pi3f, randSimple((rn.wSum, r.targetPdfSample.y)));
            M += rn.M;
        }
        res.M = M;
        r = res;
    }
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(r.currentSampleId), sg, ls))
        return float3(0.0f, 0.f, 0.f);
    r.targetPdfSample = bsdf.eval(sd, ls.dir, sg) * ls.Li;

    prevFrameReservoir[pixel.x + gScreen.x * pixel.y] = r; // for next frame;
    uint lightIndex = r.currentSampleId;
    float invPdf = r.getInvPDF();
    const uint lobeTypes = bsdf.getLobes(sd);
    if (dot(ls.dir, sd.N) <= kMinCosTheta && !(lobeTypes & (uint)LobeType::Transmission))
        return float3(0.f);
    if (dot(ls.dir, sd.N) >= -kMinCosTheta && !(lobeTypes & (uint)LobeType::Reflection))
        return float3(0.f);
    float3 n = dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN;
    float3 origin = computeRayOrigin(sd.posW, n);
    Ray ray = Ray(origin, ls.dir, 0.0f, ls.distance);
    if (traceVisibilityRay(ray))
    {
        return r.targetPdfSample * invPdf;
    }
    else
    {
        return float3(0.0f, 0.f, 0.f);
    }
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    if (kUseReSTIR)
        finalShading(dispatchThreadId.xy, gScreen);
}
