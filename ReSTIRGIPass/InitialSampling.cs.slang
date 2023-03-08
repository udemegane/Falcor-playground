#include "Scene/SceneDefines.slangh"

import Scene.Scene;
import Scene.HitInfo;

import GIReservoir;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gNormal;

RWStructuredBuffer<GISample> initSamples;

cbuffer CB{
    uint gFrameCount;
    uint2 gFrameDim;
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID){

}
