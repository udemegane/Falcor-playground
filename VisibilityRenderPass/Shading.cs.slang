#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.HitInfo;
import Scene.HitInfoType;
// import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
// import Rendering.Materials.StandardMaterial;
// import Rendering.Lights.LightHelpers;
import LoadShadingData;

// Input
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;

// Output
RWTexture2D<float4> gShadingColor;
RWTexture2D<float4> gOutColor;
RWTexture2D<float> gShadow;

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint2 gFrameDim;
}
void fillTile1Color(uint2 pixel, uint3 groupId)
{
    float x = float(groupId.x / 8);
    float y = float(groupId.y / 8);
    uint maxX = (gFrameDim.x + 127) / 128;
    uint maxY = (gFrameDim.y + 127) / 128;
    gShadingColor[pixel] = float4(float(x / maxX), 0.f, float(y / maxY), 1.0f);
}

void shading(uint2 pixel, uint2 screen)
{
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;

    if (any(pixel >= gFrameDim))
        return;
    // gOutColor[pixel] = float4(0.0f, 1.0f, 0.f, 1.0f);
    fillTile1Color(pixel, groupId);
}
