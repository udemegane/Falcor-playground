#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Geometry.GeometryHelpers;

import Utils.Math.MathHelpers;

import Utils.Sampling.SampleGenerator;

import RaytracingUtils;
import GIReservoir;
import StaticParams;
import LoadShadingData;

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gNoise;
Texture2D<float4> gDirectLighting;

RWTexture2D<float4> gColor;
RWTexture2D<float4> gDiffuseRadiance;
RWTexture2D<float4> gSpecularRadiance;

RWStructuredBuffer<GIReservoir> gIntermediateReservoirs;
// RWStructuredBuffer<GISample> gInitSamples;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
    uint gRandUint;
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

float3 finalShading(uint2 pixel, GIReservoir res, inout SampleGenerator sg)
{
    // TODO: implement this.
    // outColor = DirectLighting + sample.Lo*throughput

    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;
    // return gThroughput[pixel] * gFinalReservoirs[pixel1D].s.Lo; //* gFinalReservoirs[pixel1D].getInvPDF();
    // let res = gFinalReservoirs[pixel1D];
    // return (res.wSum + 0.0000000001) / (res.ps + 0.0000000001);
    // float accept = res.updated;
    // return accept;

    // if (kDebugSplitView)
    // {
    //     float3 estimated = pixel.x < gFrameDim.x / 2 ? res.s.Lo * getInvPDF(res) : gInitSamples[pixel1D].Lo;

    //     if (kShowVisibilityPointLi)
    //         return estimated;
    //     estimated *= pixel.x < gFrameDim.x / 2 ? res.s.weight : gInitSamples[pixel1D].weight;
    //     if (kEvalDirect)
    //         return estimated + gInitSamples[pixel1D].ns;
    //     else
    //         return estimated;
    // }
    // else
    {
        float3 color = res.s.Lo * getInvPDF(res);

        // if (false)
        // {
        //     const HitInfo hit = HitInfo(gVBuffer[pixel]);
        //     if (hit.isValid())
        //     {
        //         let lod = ExplicitLodTextureSampler(0.f);
        //         float3 primaryRayDir = gScene.camera.computeRayPinhole(pixel, gFrameDim, false).dir;
        //         float3 primaryRayOrigin = gScene.camera.getPosition();
        //         ShadingData sd = loadShadingData(hit, primaryRayDir, primaryRayOrigin, lod);
        //         let mi = gScene.materials.getMaterialInstance(sd, lod);
        //         float3 wo = (res.s.xs - res.s.xv);
        //         res.s.weight = (mi.eval(sd, wo, sg) * getInvPDF(res) * dot(wo, -primaryRayDir) + HLF_EPSILON) /
        //                        (mi.evalPdf(sd, wo, kUseImportanceSampling) + HLF_EPSILON);
        //     }
        // }

        color *= res.s.weight;

        // color = abs(res.s.invPdf); // getInvPDF(res);
        gDiffuseRadiance[pixel] = float4(color, res.s.sceneLength);
        // color = pixel.x > gFrameDim.x / 2.0 ? float(res.updated) : color;

        return color; //+ (kEvalDirect ? gInitSamples[pixel1D].ns : float3(0.f));
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
