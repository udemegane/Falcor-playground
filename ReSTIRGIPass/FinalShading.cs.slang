#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;

import GIReservoir;
import StaticParams;

Texture2D<float4> gNoise;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gSpecularRadiance;

RWStructuredBuffer<GIReservoir> gFinalReservoirs;
RWStructuredBuffer<GISample> gInitSamples;
// RWTexture2D<float3> gThroughput;

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
    // return gThroughput[pixel] * gFinalReservoirs[pixel1D].s.Lo; //* gFinalReservoirs[pixel1D].getInvPDF();
    let res = gFinalReservoirs[pixel1D];
    // return (res.wSum + 0.0000000001) / (res.ps + 0.0000000001);
    // float accept = res.updated;
    // return accept;

    if (kDebugSplitView)
    {
        float3 estimated = pixel.x < gFrameDim.x / 2 ? res.s.Lo * getInvPDF(res) : gInitSamples[pixel1D].Lo;

        if (kShowVisibilityPointLi)
            return estimated;
        estimated += pixel.x < gFrameDim.x / 2 ? estimated * res.s.weight : estimated * gInitSamples[pixel1D].weight;
        if (kEvalDirect)
            return estimated + gInitSamples[pixel1D].ns;
        else
            return estimated;
    }
    else
    {
        return res.s.Lo * getInvPDF(res) * res.s.weight + gInitSamples[pixel1D].ns;
    }

    // return res.s.Lo * gThroughput[pixel];

    // return gInitSamples[pixel1D].Lo * gThroughput[pixel];
}

[numthreads(16, 16, 1)] void main(uint3 groupId
                                  : SV_GroupID, uint3 groupThreadId
                                  : SV_GroupThreadID, uint3 dispatchThreadId
                                  : SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    gColor[pixel] = float4(finalShading(pixel), 1.0f);
}
