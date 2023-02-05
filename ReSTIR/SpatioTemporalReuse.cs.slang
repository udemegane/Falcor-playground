#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

// __exported importで補完が効かない
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
// static const bool kUseTemporalReuse = USE_TEMPORAL_REUSE;
// static const uint kTemporalReuseMaxM = TEMPORAL_REUSE_MAX_M;
// static const bool kUseAutoSetMaxM = USE_AUTO_SET_MAX_M;
// static const bool kUseSpatialReuse = USE_SPATIAL_REUSE;
void spatioTemporalReuse(uint2 pixel)
{
    gOutputColor[pixel] *= 0.2;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    spatioTemporalReuse(dispatchThreadId.xy);
}
