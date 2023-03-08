#include "Scene/SceneDefines.slangh"

import Scene.Scene;
import Scene.HitInfo;

import GIReservoir;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gSpecularRadiance;

RWStructuredBuffer<GIReservoir> giReservoirs;

ParameterBlock<Scene> gScene;


cbuffer CB{
    uint gFrameCount;
    uint2 gFrameDim;
}


[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID){
    uint2 pixel = dispatchThreadId.xy;
    gColor[pixel]=float4(0.5,0.5,0.5,1.0);
}
