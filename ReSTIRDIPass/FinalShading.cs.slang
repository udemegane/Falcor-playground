#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Geometry.GeometryHelpers;

import Utils.Math.MathHelpers;
import Rendering.Materials.IsotropicGGX;

import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import RaytracingUtils;
import Reservoir;
import StaticParams;
import LoadShadingData;

// #define is_valid(name) (is_valid_##name != 0)

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float> gDepth;
Texture2D<float4> gViewW;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gDiffuseReflectance;
RWTexture2D<float4> gSpecularRadiance;
RWTexture2D<float4> gSpecularReflectance;

RWStructuredBuffer<Reservoir> gIntermediateReservoir;

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

float3 finalShading<S : ISampleGenerator>(uint2 pixel, Reservoir res, inout S sg)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;
    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);
    float3 color = float3(0.f);
    if (hit.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod);

        demodulate(pixel, sd, mi, color);
    }
    else
    {
    }
}

void demodulate(const uint2 pixel, const ShadingData sd, const IMaterialInstance mi, const float3 color)
{
    float3 diffuceReflectance =
        (max(0.01f, mi.getProperties(sd).diffuseReflectionAlbedo + mi.getProperties(sd).specularTransmissionAlbedo));

    const float NdotV = saturate(dot(mi.getProperties(sd).guideNormal, sd.V));
    const float ggxAlpha = mi.getProperties(sd).roughness * mi.getProperties(sd).roughness;
    float3 specularReflectance = approxSpecularIntegralGGX(mi.getProperties(sd).specularReflectionAlbedo, ggxAlpha, NdotV);
    gDiffuseRadiance[pixel] = float4(color / diffuceReflectance, 1.0f);
    gSpecularRadiance[pixel] = float4(color / max(0.01f, specularReflectance), 1.0f);
    gDiffuseReflectance[pixel] = float4(diffuceReflectance, 1.0f);
    gSpecularReflectance[pixel] = float4(specularReflectance, 1.0f);
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
}
