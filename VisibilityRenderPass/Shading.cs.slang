#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.HitInfo;
import Scene.HitInfoType;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.IBSDF;
import Rendering.Materials.IBxDF;
import Rendering.Materials.IMaterial;
import Rendering.Materials.StandardMaterial;
import Rendering.Materials.InteriorListHelpers;
import Rendering.Lights.LightHelpers;
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

float3 getPrimaryRayDir(uint2 pixel, uint2 screen, const Camera camera)
{
    if (true)
    {
        return -gViewW[pixel].xyz;
    }
    else
    {
        return camera.computeRayPinhole(pixel, screen).dir;
    }
}

float3 evalDirectLighting(const IBSDF bsdf, const ShadingData sd, SampleGenerator sg)
{
    AnalyticLightSample ls;
    const uint lightCount = gScene.getLightCount();
    float3 out = float3(0.f);
    const uint lobeTypes = bsdf.getLobes(sd);
    for (uint i = 0; i < lightCount; i++)
    {
        if (!sampleLight(sd.posW, gScene.getLight(i), sg, ls))
            continue;
        if (dot(ls.dir, sd.N) <= kMinCosTheta && !(lobeTypes & (uint)LobeType::Transmission))
            continue;
        if (dot(ls.dir, sd.N) >= -kMinCosTheta && !(lobeTypes & (uint)LobeType::Reflection))
            continue;
        out += bsdf.eval(sd, ls.dir, sg) * ls.Li;
    }
    return out;
}

void shading(uint2 pixel, uint2 screen)
{
    float3 outColor = float3(0.f);
    const float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let bsdf = gScene.materials.getBSDF(sd, lod);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        outColor += bsdf.getProperties(sd).emission + evalDirectLighting(bsdf, sd, sg);
    }
    else
    {
        outColor = gScene.envMap.eval(primaryRayDir); // : kDefaultBackgroundColor;
    }

    gShadingColor[pixel] = float4(outColor, 1.0f);
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;

    if (any(pixel >= gFrameDim))
        return;
    shading(pixel, gFrameDim);
}
