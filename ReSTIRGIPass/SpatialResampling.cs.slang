#include "Scene/SceneDefines.slangh"

import Scene.Scene;
import Scene.HitInfo;

import GIReservoir;

RWStructuredBuffer<GIReservoir> gTemporalReservoirs;
RWStructuredBuffer<GIReservoir> gSpatialReservoirs;
Texture2D<float4> gNoise;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
}

void spatialResampling(uint2 pixel) {}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID) {}
