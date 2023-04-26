#include "Scene/SceneDefines.slangh"

import Scene.Scene;
import Scene.HitInfo;

import GIReservoir;

Texture2D<float4> gMotionVector;
Texture2D<float4> gNoise;

RWStructuredBuffer<GISample> initSamples;
RWStructuredBuffer<GIReservoir> gTemporalReservoirs;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
}

uint computePrevFramePix(uint2 pixel)
{
    // TODO
    return -0;
}

void temporalResampling(uint2 pixel)
{
    // section 4.2 Resampling and Shading

    // from equation(9)
    const uint prevFramePix1D = computePrevFramePix(pixel);
    GISample s = initSamples[pixel.x + gFrameDim.x * pixel.y];
    gTemporalReservoirs[prevFramePix1D].update(s, length(s.Lo) * s.invPdf, s.Lo);
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID) {}
