#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
import Scene.Scene;
import Utils.Attributes;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;

import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.LightHelpers;

import Reservoir;
import StaticParams;
import LoadShadingData;
import Params;

// #define is_valid(name) (is_valid_##name != 0)

RWStructuredBuffer<Reservoir> gTemporalReservoir;
RWStructuredBuffer<Reservoir> gIntermediateReservoir;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float> gDepth;
Texture2D<float4> gViewW;
Texture2D<float2> gMotionVector;
ParameterBlock<Params> params;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    bool isValidViewW;
}

float3 getPrimaryRayDir(uint2 pixel, uint2 screen, const Camera camera)
{
    if (isValidViewW)
    {
        return -gViewW[pixel].xyz;
    }
    else
    {
        return camera.computeRayPinhole(pixel, screen).dir;
    }
}

void sampling(uint2 pixel, uint2 screen) {}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
    sampling(pixel, gFrameDim);
}
