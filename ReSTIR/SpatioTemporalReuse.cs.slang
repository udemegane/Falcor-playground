#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Scene.HitInfoType;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Reservoir;

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint2 gScreen;
}

// Input
Texture2D<float2> gMotionVector;
Texture2D<float> gDepth;
StructuredBuffer<RISReservoir> intermediateReservoir;
// InOut
RWStructuredBuffer<RISReservoir> prevFrameReservoir;
// Output
RWTexture2D<float4> gOutputColor;

static const uint kSpatialNeigborsNum = 5;
static const float kSampleRadius = 30.0;
static const bool kUseReSTIR = USE_RESTIR;
static const bool kUseTemporalReuse = USE_TEMPORAL_REUSE;
static const uint kTemporalReuseMaxM = TEMPORAL_REUSE_MAX_M;
static const bool kUseAutoSetMaxM = USE_AUTO_SET_MAX_M;
static const bool kUseSpatialReuse = USE_SPATIAL_REUSE;

int getPrevFramePos1D(uint2 pixelPos, uint2 screen)
{
    uint2 prevPixPos = pixelPos + uint2(screen * gMotionVector[pixelPos]);
    return prevPixPos.x + screen.x * prevPixPos.y;
}

float randSimple(float2 p)
{
    return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

void spatioTemporalReuse(uint2 pixel)
{
    const uint lightCount = gScene.getLightCount();
    RISReservoir r = intermediateReservoir[pixel.x + gScreen.x * pixel.y];
    float rand = sin(gFrameCount);
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
        res.update(r.currentSampleId, r.wSum, r.targetPdfSample, randSimple((r.wSum, rprev.targetPdfSample)));
        res.update(rprev.currentSampleId, rprev.wSum, rprev.targetPdfSample, randSimple((rprev.wSum, r.targetPdfSample)));
        res.M = r.M + rprev.M;
        r = res;
    }
    if (kUseSpatialReuse)
    {
        for (uint i = 0; i < kSpatialNeigborsNum; i++)
        {
            float radius = kSampleRadius * rand;
            float angle = 2.0f * M_PI * frac(sin(gFrameCount * rand));
            uint2 neighborPos = {
                pixel.x + uint(radius * cos(angle)),
                pixel.y + uint(radius * sin(angle))
            };

            rand = randSimple(((float)neighborPos.x / rand, (float)neighborPos.y / rand));
        }
        // TODO: combine reservoirs;
    }
    prevFrameReservoir[pixel.x + gScreen.x * pixel.y] = r; // for next frame;
    // gOutputColor[pixel] *= 0.2;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    spatioTemporalReuse(dispatchThreadId.xy);
}
