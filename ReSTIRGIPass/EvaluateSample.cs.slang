#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Geometry.GeometryHelpers;

import Utils.Math.MathHelpers;
import Rendering.Materials.IsotropicGGX;

import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import RaytracingUtils;
import GIReservoir;
import RenderPasses.ReSTIRGIPass.StaticParams;
import LoadShadingData;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gNoise;
Texture2D<float4> gDirectLighting;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gDiffuseReflectance;
RWTexture2D<float4> gSpecularRadiance;
RWTexture2D<float4> gSpecularReflectance;

RWStructuredBuffer<GIReservoir> gIntermediateReservoirs;
// RWStructuredBuffer<GISample> gInitSamples;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
    uint gRandUint;
    bool readyReflectance;
}

float4 extractNoise(uint2 pixel, uint seed, bool flag)
{
    // light weight noise extracter
    bool swap = flag | ((pixel.x + pixel.y) % 2 == 0);
    uint a = swap ? pixel.x : pixel.y;
    uint b = !swap ? pixel.x : pixel.y;

    uint x = ((seed % a) + b) % gNoiseTexDim.x;
    uint y = ((seed % b) + a) % gNoiseTexDim.y;
    float4 u4 = gNoise[uint2(x, y)];
    return gNoise[uint2(gNoiseTexDim.x * u4.x, gNoiseTexDim.y * u4.y)];
}

float GetRandomNumber(float2 texCoord, uint2 pixel, int Seed)
{
    bool swap = ((pixel.x + pixel.y) % 2 == 0);

    return frac(sin(dot(texCoord.xy, float2(12.9898, 78.233)) + Seed + Seed % (swap ? pixel.x : pixel.y)) * 43758.5453);
}

GIReservoir spatialResampling(uint2 pixel, inout SampleGenerator sg)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;

    if (kUseSpatialResampling)
    {
        GIReservoir master = gIntermediateReservoirs[pixel.x + gFrameDim.x * pixel.y];
        GISample s = master.s;

        const float3 origin = computeRayOrigin(s.xv, s.nv);
        float2 texCoord = float2(pixel.x, pixel.y);
        texCoord = normalize(texCoord);
        float u = 1.0f;
        for (uint i = 0; i < kSpatialNeigborsNum; i++)
        {
            // float4 u3 = extractNoise(pixel, uint(float(gRandUint) * u), master.updated);
            // u = u3.w;
            // float3 u4 = sampleNext3D(sg);
            // float3 u3 = float3(
            //     GetRandomNumber(texCoord, pixel, gRandUint + pixel.x + pixel.y + i),
            //     GetRandomNumber(texCoord, pixel, gRandUint + pixel.x + i), GetRandomNumber(texCoord, pixel, gRandUint + pixel.y + i)
            // );
            float radius = kSampleRadius * sampleNext1D(sg);
            float angle = M_2PI * sampleNext1D(sg);
            uint2 neighbor = {
                clamp(pixel.x + uint(radius * cos(angle)), 0, gFrameDim.x), clamp(pixel.y + uint(radius * sin(angle)), 0, gFrameDim.y)
            };
            GIReservoir rn = gIntermediateReservoirs[neighbor.x + gFrameDim.x * neighbor.y];

            // angle test
            if (dot(rn.s.nv, s.nv) >= 0.8)
            {
                // calc jacobian
                float3 s2v = s.xv - rn.s.xs;
                float3 s2vNeighbor = rn.s.xv - rn.s.xs;
                float cos_current = dot(rn.s.ns, normalize(s2v));
                float cos_neighbor = dot(rn.s.ns, normalize(s2vNeighbor));
                float norm2_current = dot(s2v, s2v);
                float norm2_neighbor = dot(s2vNeighbor, s2vNeighbor);
                float invJ = abs((cos_current * norm2_neighbor + HLF_EPSILON) / (cos_neighbor * norm2_current + HLF_EPSILON));

                float weight = kUseTemporalResampling ? getInvPDF(rn) : 1.f;
                float u = sampleNext1D(sg);

                if (kDoVisibilityTestEverySample)
                {
                    Ray ray = Ray(origin, -s2v, 0.f, length(s2v));
                    if (traceVisibilityRay(ray))
                    {
                        bool accept = mergeReservoirs(master, rn, rn.ps * invJ, u);
                        if (accept)
                            setVisibilityPoint(master, s);
                        master.updated = master.updated || accept;
                    }
                }
                else
                {
                    bool accept = mergeReservoirs(master, rn, rn.ps * invJ, u);
                    if (accept)
                        setVisibilityPoint(master, s);
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
            const float3 dir = master.s.xs - s.xv;
            Ray ray = Ray(origin, dir, 0.f, length(dir));
            if (traceVisibilityRay(ray))
            {
                // updateReservoir(
                //     gIntermediateReservoirs[pixel1D], master.s, length(master.s.Lo) * master.s.invPdf * getInvPDF(master),
                //     sampleNext1D(sg)
                // );

                return master;
            }
            else
            {
                return gIntermediateReservoirs[pixel1D];
            }
        }
        else
        {
            return master;
        }
    }
    else
    {
        return gIntermediateReservoirs[pixel1D];
    }
}

float3 evalDirectAnalytic(const ShadingData sd, const IMaterialInstance mi, inout SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return float3(0.f);

    // Pick one of the analytic light sources randomly with equal probability.
    const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
    float invPdf = lightCount; // Light selection pdf = 1.0 / lightCount.

    // Sample local light source.
    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls))
        return float3(0.f);

    // Reject sample if not in the hemisphere of a BSDF lobe.
    const uint lobeTypes = mi.getLobeTypes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    if (dot(ls.dir, sd.N) <= kMinCosTheta && !hasTransmission)
        return float3(0.f);
    if (dot(ls.dir, sd.N) >= -kMinCosTheta && !hasReflection)
        return float3(0.f);

    // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
    const float3 origin = computeRayOrigin(sd.posW, dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN);

    // Test visibility by tracing a shadow ray.
    Ray ray = Ray(origin, ls.dir, 0.0f, ls.distance);
    if (!traceVisibilityRay(ray))
        return float3(0.0f);

    // Evaluate contribution.
    return mi.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

float3 finalShading(uint2 pixel, GIReservoir res, inout SampleGenerator sg)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;
    {
        float3 color = res.s.Lo * getInvPDF(res);
        float3 di = 0.f;
        const HitInfo hit = HitInfo(gVBuffer[pixel]);
        const float3 primaryRayOrigin = gScene.camera.getPosition();
        const float3 primaryRayDir = gScene.camera.computeRayPinhole(pixel, gFrameDim).dir;

        if (hit.isValid())
        {
            let lod = ExplicitLodTextureSampler(0.f);
            ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
            let mi = gScene.materials.getMaterialInstance(sd, lod);

            // di += (mi.getProperties(sd).emission);
            // di += evalDirectAnalytic(sd, mi, sg);
            float3 wo = normalize(res.s.xs - res.s.xv);

            res.s.weight = (mi.eval(sd, wo, sg) + HLF_EPSILON) / (mi.evalPdf(sd, wo, kUseImportanceSampling) + HLF_EPSILON);

            color *= res.s.weight;
            // color += di;
            if (readyReflectance)
            {
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

            // color = color / sr;
        }
        else
        {
        }

        // color *= res.s.weight;

        // color = abs(res.s.invPdf); // getInvPDF(res);
        // color = pixel.x > gFrameDim.x / 2.0 ? float(res.updated) : color;
        return color;
        return di; //+ (kEvalDirect ? gInitSamples[pixel1D].ns : float3(0.f));
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
    // float3 hijack = gIntermediateReservoirs[pixel.x + gFrameDim.x * pixel.y].s.debug;
    float3 finalcolor = finalShading(pixel, spatialResampling(pixel, sg), sg);
    gColor[pixel] = float4(finalcolor, 1.0f);
    // gColor[pixel] = float4(pixel.y > gFrameDim.y / 2.0 ? hijack : finalcolor, 1.0f);

    // gColor[pixel] = float4(hijack, 1.0f);
    // float3 tile = float3(float(groupThreadId.x) / 16.f, float(groupThreadId.y) / 16.f, 0.0);
    // gColor[pixel] = float4(tile, 1.0f);
}
