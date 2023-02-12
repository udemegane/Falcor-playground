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

struct RISMonoReservoir
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

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    gShadow[pixel] = float(1.0f);
}
