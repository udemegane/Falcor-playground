/***************************************************************************
 # Copyright (c) 2023, udemegane All rights reserved.
 **************************************************************************/

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

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float> gDepth;
Texture2D<float4> gViewW;
Texture2D<float4> gNormal;

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

Reservoir spatialResampling<S : ISampleGenerator>(uint2 pixel, const ShadingData sd, bool isValidHit, inout S sg)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;

    if (kUseReSTIR && kUseSpatialResampling && isValidHit)
    {
        Reservoir r = Reservoir.unpack(gIntermediateReservoir[pixel1D]);
        let lod = ExplicitLodTextureSampler(0.f);
        // ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        float3 N = gNormal[pixel].xyz;
        [unroll]
        for (uint i = 0; i < kSpatialNeighbors; i++)
        {
            float radius = kSampleRadius * sampleNext1D(sg);
            float angle = M_2PI * sampleNext1D(sg);
            uint2 neighbor = {
                clamp(pixel.x + uint(radius * cos(angle)), 0, gFrameDim.x), clamp(pixel.y + uint(radius * sin(angle)), 0, gFrameDim.y)
            };
            Reservoir ri = Reservoir.unpack(gIntermediateReservoir[neighbor.x + gFrameDim.x * neighbor.y]);
            float3 neighborN = gNormal[neighbor].xyz;
            if (dot(neighborN, N) > 0.9)
            {
                let mi = gScene.materials.getMaterialInstance(sd, lod);
                float pi = length(mi.eval(sd, ri.s.dir, sg) * ri.s.Li);
                r.merge(ri, pi, sampleNext1D(sg));
                if (r.M > kSpatialMax)
                {
                    r.wSum *= float(kSpatialMax) / r.M;
                    r.M = kSpatialMax;
                }
            }
        }
        return r;
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

float3 finalShading<S : ISampleGenerator>(uint2 pixel, Reservoir res, const ShadingData sd, bool isValidHit, inout S sg)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;
    // const HitInfo hit = HitInfo(gVBuffer[pixel]);
    // const float3 primaryRayOrigin = gScene.camera.getPosition();
    // const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);
    float3 color = float3(0.f);
    if (isValidHit)
    {
        let lod = ExplicitLodTextureSampler(0.f);
        // ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod);
        color = recalculateLighting(res.s, sd, mi, sg) * res.getInvPDF() + mi.getProperties(sd).emission;
        demodulate(pixel, sd, mi, color);
        return color;
    }
    else
    {
        color = gScene.envMap.eval(res.s.dir);
        gDiffuseRadiance[pixel] = float4(color, 1.f);
        gSpecularRadiance[pixel] = float4(0.f, 0.f, 0.f, 1.0f);
        gDiffuseReflectance[pixel] = float4(1.0f);
        gSpecularReflectance[pixel] = float4(0.01f);
        return color;
    }
}

void demodulate(const uint2 pixel, const ShadingData sd, const IMaterialInstance mi, const float3 color)
{
    float3 diffuceReflectance =
        (max(0.01f, mi.getProperties(sd).diffuseReflectionAlbedo + mi.getProperties(sd).specularTransmissionAlbedo));

    const float NdotV = saturate(dot(mi.getProperties(sd).guideNormal, sd.V));
    const float ggxAlpha = mi.getProperties(sd).roughness * mi.getProperties(sd).roughness;
    float3 specularReflectance = max(0.01f, approxSpecularIntegralGGX(mi.getProperties(sd).specularReflectionAlbedo, ggxAlpha, NdotV));
    gDiffuseRadiance[pixel] = float4(color / diffuceReflectance, 1.0f);
    gSpecularRadiance[pixel] = float4(color / specularReflectance, 1.0f);
    gDiffuseReflectance[pixel] = float4(diffuceReflectance, 1.0f);
    gSpecularReflectance[pixel] = float4(specularReflectance, 1.0f);
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    const bool isValidHit = hit.isValid();
    let lod = ExplicitLodTextureSampler(0.f);
    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);
    ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
    float3 color = finalShading(pixel, spatialResampling(pixel, sd, isValidHit, sg), sd, isValidHit, sg);
    gColor[pixel] = float4(color, 1.0f);
}
