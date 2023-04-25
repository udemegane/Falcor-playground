#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Scene.RaytracingInline;
import Utils.Geometry.GeometryHelpers;

import Utils.Math.MathHelpers;

import Utils.Sampling.SampleGenerator;

import Utils.Debug.PixelDebug;

import Rendering.Utils.PixelStats;

import GIReservoir;
static const bool kUseSpatialResampling = true;
static const uint kSpatialNeigborsNum = 20;
static const uint kSampleRadius = 80;
static const uint kSpatialMax = 500;

RWStructuredBuffer<GIReservoir> gTemporalReservoirs;
RWStructuredBuffer<GIReservoir> gIntermediateReservoirs;
RWStructuredBuffer<GIReservoir> gSpatialReservoirs;
Texture2D<float4> gNoise;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
}

bool traceVisibilityRay(const Ray ray)
{
    logTraceRay(PixelStatsRayType::Visibility);
    SceneRayQuery<true> srq;
    return srq.traceVisibilityRay(ray, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff);
}

void spatialResampling(uint2 pixel)
{
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;

    gTemporalReservoirs[pixel1D] = gIntermediateReservoirs[pixel1D];

    if (kUseSpatialResampling)
    {
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        // TODO:
        GIReservoir master = gIntermediateReservoirs[pixel.x + gFrameDim.x * pixel.y];
        GISample s = gIntermediateReservoirs[pixel.x + gFrameDim.x * pixel.y].s;
        const float3 origin = computeRayOrigin(s.xv, s.nv);

        // master.update(s, length(s.Lo) * s.invPdf, sampleNext1D(sg));
        for (uint i = 0; i < kSpatialNeigborsNum; i++)
        {
            float2 u2 = sampleNext2D(sg);
            float radius = kSampleRadius * u2.x;
            float angle = M_2PI * u2.y;
            uint2 neighbor = {
                clamp(pixel.x + uint(radius * cos(angle)), 0, gFrameDim.x), clamp(pixel.y + uint(radius * sin(angle)), 0, gFrameDim.y)
            };

            GIReservoir rn = gIntermediateReservoirs[neighbor.x + gFrameDim.x * neighbor.y];
            // depth test
            // angle test
            if (dot(rn.s.nv, s.nv) >= 0.9)
            {
                float3 s2v = s.xv - rn.s.xs;
                float3 s2vNeighbor = rn.s.xv - rn.s.xs;
                float cos_current = dot(rn.s.ns, normalize(s2v));
                float cos_neighbor = dot(rn.s.ns, normalize(s2vNeighbor));
                float norm2_current = dot(s2v, s2v);
                float norm2_neighbor = dot(s2vNeighbor, s2vNeighbor);
                float invJ = abs((cos_neighbor * norm2_current) / (cos_current * norm2_neighbor));
                // master.update(rn.s,, sampleNext1D(sg));
                // master.update(rn.s, length(rn.s.Lo) * rn.s.invPdf * invJ, sampleNext1D(sg));
                master.updated = master.updated || master.merge(rn, length(rn.ps) * invJ * length(rn.s.weight), sampleNext1D(sg));

                // float weight = 0.f;
                // Ray ray = Ray(origin, -s2v, 0.f, length(s2v));
                // if (traceVisibilityRay(ray))
                //     master.updated = master.updated || master.merge(rn, length(rn.ps) * invJ * length(rn.s.weight), sampleNext1D(sg));

                //                const float3 origin = computeRayOrigin();
            }
            if (master.M > kSpatialMax)
            {
                master.wSum *= float(kSpatialMax) / master.M;
                master.M = kSpatialMax;
            }
        }
        gSpatialReservoirs[pixel1D] = master;

        const float3 dir = master.s.xs - s.xv;
        Ray ray = Ray(origin, dir, 0.f, length(dir));
        if (traceVisibilityRay(ray))
            gSpatialReservoirs[pixel1D] = master;
        else
            gSpatialReservoirs[pixel1D] = gIntermediateReservoirs[pixel1D];

        return;
    }
    else
    {
        gSpatialReservoirs[pixel1D] = gIntermediateReservoirs[pixel1D];
        return;
    }
    return;
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    spatialResampling(pixel);
}
