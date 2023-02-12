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

static const uint kSpatialNeigborsNum = 4;
static const float kSampleRadius = 5.0;
static const bool kUseReSTIR = USE_RESTIR;
static const bool kUseTemporalReuse = USE_TEMPORAL_REUSE;
static const uint kTemporalReuseMaxM = TEMPORAL_REUSE_MAX_M;
static const bool kUseAutoSetMaxM = USE_AUTO_SET_MAX_M;
static const bool kUseSpatialReuse = USE_SPATIAL_REUSE;
static const bool kUseFixWeight = USE_FIXWEIGHT;

int getPrevFramePos1D(uint2 pixelPos, uint2 screen)
{
    uint2 prevPixPos = pixelPos + uint2(screen * gMVec[pixelPos]);
    int prevPixPos1D = prevPixPos.x + screen.x * prevPixPos.y;
    if (prevPixPos1D < 0 || prevPixPos1D > screen.x * screen.y)
        return -1;
    else
        return prevPixPos1D;
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
        int prevPixel = getPrevFramePos1D(pixel, gScreen);
        if (prevPixel != -1)
        {
            RISReservoir rprev = prevFrameReservoir[prevPixel];

            // clamp previous frame reservoir length.
            uint max = kUseAutoSetMaxM ? lightCount / 4 : kTemporalReuseMaxM;
            if (rprev.M > r.M * max)
            {
                float ratio = ((float)max * r.M / rprev.M);
                rprev.wSum *= ratio;
                rprev.M = max * r.M;
            }
            // combine reservoirs
            {
                CombinedReservoirFactory crf = CombinedReservoirFactory();
                crf.update(r);
                if (false /*kUseFixWeight*/)
                {
                    AnalyticLightSample ls;
                    float3 pi3f = float3(0.f);
                    if (sampleLight(sd.posW, gScene.getLight(rprev.currentSampleId), sg, ls))
                    {
                        pi3f = bsdf.eval(sd, ls.dir, sg) * ls.Li;
                        crf.update(rprev, pi3f);
                    }
                }
                else
                {
                    crf.update(rprev);
                }

                r = crf.getCombinedReservoir();
            }
        }
    }

    prevFrameReservoir[pixel.x + gScreen.x * pixel.y] = r; // for next frame;

    if (kUseSpatialReuse)
    {
        CombinedReservoirFactory crf = CombinedReservoirFactory();
        crf.update(r);

        for (uint i = 0; i < kSpatialNeigborsNum; i++)
        {
            rand = randSimple((r.targetPdfSample.x * rand * 3.0, r.wSum));
            // Select Negihbor pixel.
            float radius = kSampleRadius * rand;
            float angle = 2.0f * M_PI * frac(sin(gFrameCount * rand));
            uint2 neighborPos = {
                clamp(pixel.x + uint(radius * cos(angle)), 0, screen.x),
                clamp(pixel.y + uint(radius * sin(angle)), 0, screen.y)
            };

            // Skip loop when neighbor pixel is too far.
            if (gDepth[pixel] > 1.05 * gDepth[neighborPos] || gDepth[pixel] < 0.95 * gDepth[neighborPos])
            {
                continue;
            }
            // Combine Reservoirs.
            {
                RISReservoir rn = intermediateReservoir[neighborPos.x + screen.x * neighborPos.y];
                if (kUseFixWeight)
                {
                    float3 pi3f = float3(0.f);
                    AnalyticLightSample ls;
                    if (sampleLight(sd.posW, gScene.getLight(rn.currentSampleId), sg, ls))
                    {
                        pi3f = bsdf.eval(sd, ls.dir, sg) * ls.Li;
                        crf.update(rn, pi3f);
                    }
                }
                else
                {
                    crf.update(rn);
                }
            }
        }
        r = crf.getCombinedReservoir();
    }

    // prevFrameReservoir[pixel.x + gScreen.x * pixel.y] = r; // for next frame;

    uint lightIndex = r.currentSampleId;
    float invPdf = r.getInvPDF();

    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(r.currentSampleId), sg, ls))
        return float3(0.0f, 0.f, 0.f);

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
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gScreen))
        return;
    if (kUseReSTIR)
        finalShading(pixel, gScreen);
}
