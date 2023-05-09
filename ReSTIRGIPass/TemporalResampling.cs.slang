#include "Scene/SceneDefines.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Utils.Color.ColorHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;

import GIReservoir;
import StaticParams;

Texture2D<float4> gMotionVector;

RWStructuredBuffer<PackedGIReservoir> gTemporalReservoirs;
RWStructuredBuffer<PackedGIReservoir> gIntermediateReservoirs;

cbuffer CB
{
    uint gFrameCount;
    uint2 gFrameDim;
}

int2 getPrevPixel(float3 pos, Camera camera)
{
    float4 prevClip = mul(camera.data.prevViewProjMatNoJitter, float4(pos, 1.0));
    float2 prevUV = float2(((prevClip.x) / (prevClip.w)) * 0.5 + 0.5, ((-prevClip.y) / (prevClip.w)) * 0.5 + 0.5);
    int2 prevPix = int2(prevUV.x * (float)gFrameDim.x, prevUV.y * (float)gFrameDim.y);
    return prevPix;
}

void temporalResampling<S : ISampleGenerator>(const uint2 pixel, const float3 pos, const GISample s, inout S sg)
{
    float u = sampleNext1D(sg);

    int2 prevPix = getPrevPixel(pos, gScene.camera);
    // int2 prevPixelPos = prevPix; // + int2(gFrameDim * gMotionVector[pixel].xy);
    // int2 prevPix = (int2)pixel + int2(gFrameDim * gMotionVector[pixel].xy);
    int prevFramePix1D = prevPix.x + (int)gFrameDim.x * prevPix.y;
    GIReservoir currentReservoir = GIReservoir();

    updateReservoir(currentReservoir, s, luminance(s.Lo) * s.invPdf, 0.0f);

    if (kUseTemporalResampling && prevPix.x >= 0 && prevPix.y >= 0 && prevPix.x < gFrameDim.x && prevPix.y < gFrameDim.y)
    {
        GIReservoir res = GIReservoir.unpack(gTemporalReservoirs[prevFramePix1D]);

        // float depthRatio =
        //     (length(pos - gScene.camera.data.posW) + HLF_EPSILON) / (length(res.s.xv - gScene.camera.data.prevPosW) + HLF_EPSILON);

        bool filter = !((dot(res.s.nv, s.nv) < 0.7f && length(res.s.xv - s.xv) > 0.2f) || (length(s.nv - res.s.nv) > 0.4));
        if (filter)
        {
            bool accept = updateReservoir(res, s, luminance(s.Lo) * s.invPdf, u);
            currentReservoir = res;
            if (currentReservoir.M > kTemporalMax)
            {
                currentReservoir.wSum *= (float)kTemporalMax / currentReservoir.M;
                currentReservoir.M = kTemporalMax;
            }
        }
    }

    gIntermediateReservoirs[pixel.x + gFrameDim.x * pixel.y] = currentReservoir.pack();
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;
    GIReservoir r = GIReservoir.unpack(gIntermediateReservoirs[pixel.x + gFrameDim.x * pixel.y]);
    SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
    temporalResampling(pixel, computeRayOrigin(r.s.xv, r.s.nv), r.s, sg);
}
