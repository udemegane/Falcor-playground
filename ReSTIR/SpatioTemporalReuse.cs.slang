import Reservoir;

// Input
Texture2D<float2> gMotionVector;
Texture2D<float> gDepth;
StructuredBuffer<RISReservoir> outputReservoir;
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
