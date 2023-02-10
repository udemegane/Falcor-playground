#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Utils.PixelStats;
import Rendering.Lights.LightHelpers;
import Reservoir;

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint gPRNGDimension;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;

// InOut
// RWStructuredBuffer<RISReservoir> prevFrameReservoir;
RWStructuredBuffer<RISReservoir> outputReservoir;
// RWStructuredBuffer<Params> params;

// Output
RWTexture2D<float4> gOutputColor;

#define is_valid(name) (is_valid_##name != 0)

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayMax = FLT_MAX;

// ReSTIR constant values
static const bool kUseReSTIR = USE_RESTIR;
static const uint kRISSampleNums = RIS_SAMPLE_NUMS;
static const bool kUseTemporalReuse = USE_TEMPORAL_REUSE;
static const uint kTemporalReuseMaxM = TEMPORAL_REUSE_MAX_M;
static const bool kUseAutoSetMaxM = USE_AUTO_SET_MAX_M;
static const bool kUseSpatialReuse = USE_SPATIAL_REUSE;

// // shadow ray strcuture
// struct ShadowRayData
// {
//     bool visible;
// }

// float3 getPrimaryRayDir(uint2 pixel, uint2 screen, const Camera camera)
// {
//     if (is_valid(gViewW))
//     {
//         return -gViewW[pixel].xyz;
//     }
//     else
//     {
//         return camera.computeRayPinhole(pixel, screen).dir;
//     }
// }

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
}
