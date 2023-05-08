#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Geometry.GeometryHelpers;
import Utils.Color.ColorHelpers;
import Utils.Math.MathHelpers;
import Rendering.Materials.IsotropicGGX;

import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import RaytracingUtils;
import GIReservoir;
import StaticParams;
import LoadShadingData;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gNoise;
Texture2D<float4> gDirectLighting;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gEnvColor;
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gDiffuseReflectance;
RWTexture2D<float4> gSpecularRadiance;
RWTexture2D<float4> gSpecularReflectance;

RWStructuredBuffer<PackedGIReservoir> gIntermediateReservoirs;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
    uint gRandUint;
}

GIReservoir spatialResampling<S : ISampleGenerator>(uint2 pixel, inout S sg)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;

    if (kUseSpatialResampling)
    {
        GIReservoir master = GIReservoir.unpack(gIntermediateReservoirs[pixel.x + gFrameDim.x * pixel.y]);
        GISample s = master.s;

        const float3 origin = computeRayOrigin(s.xv, s.nv);

        [unroll]
        for (uint i = 0; i < kSpatialNeigborsNum; i++)
        {
            float radius = kSampleRadius * sampleNext1D(sg);
            float angle = M_2PI * sampleNext1D(sg);
            uint2 neighbor = {
                clamp(pixel.x + uint(radius * cos(angle)), 0, gFrameDim.x), clamp(pixel.y + uint(radius * sin(angle)), 0, gFrameDim.y)
            };
            GIReservoir rn = GIReservoir.unpack(gIntermediateReservoirs[neighbor.x + gFrameDim.x * neighbor.y]);

            // angle test
            if (dot(rn.s.nv, s.nv) >= 0.9)
            {
                // calc jacobian
                float3 s2v = s.xv - rn.s.xs;
                float3 s2vNeighbor = rn.s.xv - rn.s.xs;
                float cos_current = abs(dot(rn.s.ns, normalize(s2v)));
                float cos_neighbor = abs(dot(rn.s.ns, normalize(s2vNeighbor)));
                float norm2_current = dot(s2v, s2v);
                float norm2_neighbor = dot(s2vNeighbor, s2vNeighbor);
                float invJ = abs((cos_neighbor * norm2_current) / (cos_current * norm2_neighbor + HLF_EPSILON));

                float weight = kUseTemporalResampling ? getInvPDF(rn) : 1.f;
                float u = sampleNext1D(sg);

                if (kDoVisibilityTestEverySample)
                {
                    Ray ray = Ray(origin, -s2v, 0.f, length(s2v));
                    if (!traceVisibilityRay(ray))
                    {
                        bool accept = mergeReservoirs(master, rn, luminance(rn.s.Lo) * invJ, u);
                        if (accept)
                            setVisibilityPoint(master, s);
                        else
                            master.M -= rn.M;
                        master.updated = master.updated || accept;
                    }
                }
                else
                {
                    // bool accept = updateReservoir(master, rn.s, luminance(rn.s.Lo) * invJ * weight, u);
                    // rn.s.invPdf = getInvPDF(rn);
                    bool accept = mergeReservoirs(master, rn, rn.ps * invJ, u);
                    if (accept)
                        setVisibilityPoint(master, s);
                    else
                        master.M -= rn.M;

                    master.updated = master.updated || accept;
                }
            }
        }

        if (master.M > kSpatialMax)
        {
            master.wSum *= float(kSpatialMax) / master.M;
            master.M = kSpatialMax;
        }

        if (!kDoVisibilityTestEverySample)
        {
            if (master.updated)
            {
                const float3 dir = master.s.xs - s.xv;
                Ray ray = Ray(origin, dir, 0.f, length(dir));
                if (!traceVisibilityRay(ray))
                {
                    return master;
                }
            }
            GIReservoir r = GIReservoir.unpack(gIntermediateReservoirs[pixel1D]);
            return r;
        }
        else
        {
            return master;
        }
    }
    else
    {
        GIReservoir r = GIReservoir.unpack(gIntermediateReservoirs[pixel1D]);
        return r;
    }
}

float3 finalShading<S : ISampleGenerator>(uint2 pixel, GIReservoir res, inout S sg)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;
    {
        float3 color = res.s.Lo * getInvPDF(res);
        const HitInfo hit = HitInfo(gVBuffer[pixel]);
        const float3 primaryRayOrigin = gScene.camera.getPosition();
        const float3 primaryRayDir = gScene.camera.computeRayPinhole(pixel, gFrameDim).dir;

        if (hit.isValid())
        {
            let lod = ExplicitLodTextureSampler(0.f);
            ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
            let mi = gScene.materials.getMaterialInstance(sd, lod);
            float3 emission = mi.getProperties(sd).emission;
            gEnvColor[pixel] = float4(emission, 1.0f);

            float3 wo = normalize(res.s.xs - res.s.xv);

            // res.s.weight = (mi.eval(sd, wo, sg) + HLF_EPSILON) / (mi.evalPdf(sd, wo, kUseImportanceSampling) + HLF_EPSILON);

            color *= res.s.weight;
            if (kReadyReflectanceData)
            {
                color += gDirectLighting[pixel].xyz;
                float3 diffuseRadiance = color / gDiffuseReflectance[pixel].xyz;
                gDiffuseRadiance[pixel] = float4(diffuseRadiance, res.s.sceneLength);

                float3 specularRadiance = color / max(0.01f, gSpecularReflectance[pixel].xyz);
                gSpecularRadiance[pixel] = float4(specularRadiance, res.s.sceneLength);
            }
            else
            {
                float3 diffuceReflectance =
                    (max(0.01f, mi.getProperties(sd).diffuseReflectionAlbedo + mi.getProperties(sd).specularTransmissionAlbedo));
                float3 diffuseRadiance = color / diffuceReflectance;
                gDiffuseRadiance[pixel] = float4(diffuseRadiance, res.s.sceneLength);
                gDiffuseReflectance[pixel] = float4(diffuceReflectance, 1.0f);

                const float NdotV = saturate(dot(mi.getProperties(sd).guideNormal, sd.V));
                const float ggxAlpha = mi.getProperties(sd).roughness * mi.getProperties(sd).roughness;
                float3 sr = approxSpecularIntegralGGX(mi.getProperties(sd).specularReflectionAlbedo, ggxAlpha, NdotV);
                float3 specularRadiance = color / max(0.01f, sr);
                gSpecularRadiance[pixel] = float4(specularRadiance, res.s.sceneLength);
                gSpecularReflectance[pixel] = float4(sr, 1.0f);
            }
        }
        else
        {
            if (true)
            {
                // color += gDirectLighting[pixel].xyz;
                gEnvColor[pixel] = float4(color, 1.0f);
                float3 diffuseRadiance = color / gDiffuseReflectance[pixel].xyz;
                gDiffuseRadiance[pixel] = float4(diffuseRadiance, res.s.sceneLength);
                float3 specularRadiance = color / max(0.01f, gSpecularReflectance[pixel].xyz);
                gSpecularRadiance[pixel] = float4(specularRadiance, res.s.sceneLength);
            }
            else
            {
                gDiffuseRadiance[pixel] = float4(color, res.s.sceneLength);
                gDiffuseReflectance[pixel] = float4(1.0f);
                gSpecularRadiance[pixel] = float4(0.f, 0.f, 0.f, res.s.sceneLength);
                gSpecularReflectance[pixel] = float4(0.01f);
            }
        }
        return color;
    }
}

[numthreads(16, 16, 1)]
void main(
    uint3 groupId: SV_GroupID,
    uint3 groupThreadId: SV_GroupThreadID,
    uint3 dispatchThreadId: SV_DispatchThreadID,
    uint3 groupIndex: SV_GroupIndex
)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
    SampleGenerator sg = SampleGenerator(pixel, gRandUint);
    float3 finalcolor = finalShading(pixel, spatialResampling(pixel, sg), sg);
    gColor[pixel] = float4(finalcolor, 1.0f);
}
