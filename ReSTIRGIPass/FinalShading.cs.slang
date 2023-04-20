#include "Scene/SceneDefines.slangh"

import Scene.Scene;
import Scene.HitInfo;

import GIReservoir;
Texture2D<float4> gNoise;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gSpecularRadiance;

RWStructuredBuffer<GIReservoir> gFinalReservoirs;
RWStructuredBuffer<GISample> gInitSamples;
RWTexture2D<float3> gThroughput;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
}

float3 finalShading(uint2 pixel)
{
    // TODO: implement this.
    // outColor = DirectLighting + sample.Lo*throughput
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;
    return gThroughput[pixel] * gFinalReservoirs[pixel1D].s.Lo; //* gFinalReservoirs[pixel1D].getInvPDF();
    return gInitSamples[pixel1D].Lo * gThroughput[pixel];
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    gColor[pixel] = float4(finalShading(pixel), 1.0f);
}
