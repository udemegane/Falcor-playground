#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.HitInfo;
import Scene.HitInfoType;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
import Rendering.Lights.LightHelpers;
import Reservoir;
import RaytraceUtils;
// Input
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;

// Output
RWStructuredBuffer<RISReservoir> outputReservoir;
RWTexture2D<float4> gOutputColor;

// ReSTIR constant values
static const bool kUseReSTIR = USE_RESTIR;
static const uint kRISSampleNums = RIS_SAMPLES;

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint2 gScreen;
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

float randSimple(float2 p)
{
    return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

void prepareReservoir(const uint2 pixel, const uint2 screen, const ShadingData sd, const IBSDF bsdf, SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();

    if (kUseReSTIR && lightCount != 0)
    {

        RISReservoir r = RISReservoir();

        for (uint i = 0; i < kRISSampleNums; i++)
        {
            float2 rand = sampleNext2D(sg);
            // Sample LightID from uniform distribution
            const uint xi = min(uint(rand.x * lightCount), lightCount - 1);
            AnalyticLightSample ls;
            // Calculate from target distribution Fs*G*Li
            float3 pi3f = float3(0.000001f);
            if (sampleLight(sd.posW, gScene.getLight(xi), sg, ls))
                pi3f = bsdf.eval(sd, ls.dir, sg) * ls.Li;

            // Calculate weight proportional to p(xi)/q(xi).
            // q() is uniform distribution, Always Return 1/LightCount.
            // p(xi) is Fs*G*Li. (exclude V())
            // So weight is pi * lightCount.
            float pi = length(pi3f);
            float wi = pi * lightCount; // lightCount means invPdf
            r.update(xi, wi, pi3f, rand.y);
        }
        outputReservoir[pixel.x + screen.x * pixel.y] = r;
    }
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{

    uint2 pixel = dispatchThreadId.xy;
    const float3 primaryRayDir = getPrimaryRayDir(pixel, gScreen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);

        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);

        let bsdf = gScene.materials.getBSDF(sd, lod);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        prepareReservoir(pixel, gScreen, sd, bsdf, sg);
    }
    else
    {
    }
}
