#include "Scene/SceneDefines.slangh"

import Scene.Scene;
import Scene.HitInfo;

import GIReservoir;

Texture2D<float4> gMotionVector;
Texture2D<float4> gNoise;

RWStructuredBuffer<GISample> initSamples;
RWStructuredBuffer<GIReservoir> giReservoirs;


cbuffer CB{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;

}


[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID){

}
