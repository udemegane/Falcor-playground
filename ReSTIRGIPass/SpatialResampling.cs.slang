#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Utils.Math.MathHelpers;
import Utils.Sampling.SampleGenerator;

import GIReservoir;
static const uint kSpatialNeigborsNum = 10;
static const uint kSampleRadius = 15;
RWStructuredBuffer<GIReservoir> gTemporalReservoirs;
RWStructuredBuffer<GIReservoir> gSpatialReservoirs;
Texture2D<float4> gNoise;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
    uint2 gNoiseTexDim;
}

void spatialResampling(uint2 pixel)
{
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
    // TODO:
    GIReservoir master = GIReservoir();
    GISample s = gTemporalReservoirs[pixel.x + gFrameDim.x * pixel.y].s;
    master.update(s, length(s.Lo) * s.invPdf, s.rand);
    for (uint i = 0; i < kSpatialNeigborsNum; i++)
    {
        float2 u2 = sampleNext2D(sg);
        float radius = kSampleRadius * u2.x;
        float angle = 2.0f * M_PI * u2.y;
        uint2 neighbor = {
            clamp(pixel.x + uint(radius * cos(angle)), 0, gFrameDim.x), clamp(pixel.y + uint(radius * sin(angle)), 0, gFrameDim.y)
        };
        // depth test
        // if ()
        // {}
        {
            GIReservoir rn = gTemporalReservoirs[neighbor.x + gFrameDim.x * neighbor.y];
            float3 q2q = s.xs - s.xv;
            float3 r2q = rn.s.xs - s.xv;
            float cos_r = dot(s.nv, normalize(r2q));
            float cos_q = dot(s.nv, normalize(q2q));
            float len_q = q2q.x * q2q.x + q2q.y * q2q.y + q2q.z * q2q.z;
            float len_r = r2q.x * r2q.x + r2q.y * r2q.y + r2q.z * r2q.z;
            float J = abs((cos_r * len_q) / (cos_q * len_r));
            master.merge(rn, length(rn.ps) / J);
        }
        if (master.M > 500)
        {
            master.wSum *= 500.0 / master.M;
            master.M = 500;
        }
    }
    uint pixel1D = pixel.x + gFrameDim.x * pixel.y;
    // gSpatialReservoirs[pixel1D] = gTemporalReservoirs[pixel1D];
    gSpatialReservoirs[pixel1D] = master;
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    spatialResampling(pixel);
}
