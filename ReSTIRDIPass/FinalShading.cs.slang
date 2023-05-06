#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Geometry.GeometryHelpers;

import Utils.Math.MathHelpers;
import Rendering.Materials.IsotropicGGX;

import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import RenderPasses.ReSTIRDIPass.RaytracingUtils;
import RenderPasses.ReSTIRDIPass.Reservoir;
import RenderPasses.ReSTIRDIPass.StaticParams;
import RenderPasses.ReSTIRDIPass.LoadShadingData;

// #define is_valid(name) (is_valid_##name != 0)

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float> gDepth;
Texture2D<float4> gViewW;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gDiffuseReflectance;
RWTexture2D<float4> gSpecularRadiance;
RWTexture2D<float4> gSpecularReflectance;

RWStructuredBuffer<PackedReservoir> gIntermediateReservoir;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    bool isValidViewW;
}

enum class GenericLightType
{
    EnvMap,
    Emissive,
    Analytic
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

Reservoir spatialResampling(uint2 pixel, inout SampleGenerator sg)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;
    if (false)
    {
        // TODO: Spatial Resampling
        return Reservoir();
    }
    else
    {
        Reservoir r = Reservoir.unpack(gIntermediateReservoir[pixel1D]);
        return r;
    }
}

float3 recalculateLighting<S : ISampleGenerator>(const Sample s, const ShadingData sd, const IMaterialInstance mi, inout S sg)
{
    const float3 n = max(sd.N, sd.faceN);
    const float3 origin = computeRayOrigin(sd.posW, dot(n, s.dir) >= 0.f ? n : -n);
    Ray ray = Ray(origin, s.dir, 0.f, s.length);
    if (!traceVisibilityRay(ray))
        return float3(0.f);
    return mi.eval(sd, s.dir, sg) * s.Li;
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
        color = recalculateLighting(res.s, sd, mi, sg) * res.getInvPDF() + mi.getProperties(sd).emission;
        demodulate(pixel, sd, mi, color);
        return color;
    }
    else
    {
        color = gScene.envMap.eval(res.s.dir);
        gDiffuseRadiance[pixel] = float4(color, 1.f);
        gSpecularRadiance[pixel] = float4(0.f);
        gDiffuseReflectance[pixel] = float4(1.0f);
        gSpecularRadiance[pixel] = float4(0.f);
        return color;
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
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
    float3 color = finalShading(pixel, spatialResampling(pixel, sg), sg);
    gColor[pixel] = float4(color, 1.0f);
}
