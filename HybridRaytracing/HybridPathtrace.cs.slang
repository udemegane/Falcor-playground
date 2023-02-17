#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Scene.HitInfoType;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Utils.PixelStats;
import Rendering.Lights.LightHelpers;
// import Rendering.Lights.EmissiveLightSamplerHelpers;
// import Rendering.Lights.EmissiveLightSamplerInterface;
import TraceRay;
import LoadShadingData;

cbuffer PerframeCB
{
    uint gFrameCount;
    uint2 gFrameDim;
}

// Input
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float4> gPosW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;

// Output
RWTexture2D<float4> gOutColor;

#define is_valid(name) (is_valid_##name != 0)

static const bool kUseAlphaTest = true;
static const uint StepSize = 20;
static const uint kMaxBounces = MAX_BOUNSES;
static const bool kUseHybrid = USE_HYBRID;

float3 getPrimaryRayDir(uint2 pixel, uint2 screen, const Camera camera)
{
    if (is_valid(gViewW))
    {
        return -gViewW[pixel].xyz;
    }
    else
    {
        return camera.computeRayPinhole(pixel, screen).dir;
    }
}

bool traceRaySS(inout uint2 hitPix, const float3 rayOrigin, const float3 rayEnd, uint2 screen)
{
    return traceRaySSNaive(hitPix, rayOrigin, rayEnd, screen);
    // TODO: Implement Efficient Screen Space Raytracing by DDA
    /**
     *
     **/
}

inline bool checkIntersect(float posZ, float depth)
{
    return posZ < depth ? true : false;
}

inline bool isSamePix(uint2 pix1, uint2 pix2)
{
    return pix1.x == pix2.x && pix1.y == pix2.y;
}

float3 evalPrimaryRay(const ShadingData sd, IBSDF bsdf, SampleGenerator sg)
{
    float3 color = float3(0.f);
    const uint lightCount = gScene.getLightCount();
    if (lightCount != 0)
    {
        const uint id = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);
        AnalyticLightSample ls;
        if (sampleLight(sd.posW, gScene.getLight(id), sg, ls))
        {
            const uint lobeTypes = bsdf.getLobes(sd);
            // const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
            // const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
            // if (dot(ls.dir, sd.N) <= kMinCosTheta && !hasTransmission)
            //     return float3(0.f);
            // if (dot(ls.dir, sd.N) >= -kMinCosTheta && !hasReflection)
            //     return float3(0.f);
            const float3 n = dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN;
            const float3 origin = computeRayOrigin(sd.posW, n);
            const Ray ray = Ray(origin, ls.dir, 0.f, ls.distance);
            uint2 pix = uint2(0u);
            if (!traceRaySS(pix, origin, ls.dir * ls.distance, gFrameDim)) //!
            {
                float invPdf = lightCount;
                color += bsdf.eval(sd, ls.dir, sg) * ls.Li * invPdf;
            }
        }
    }
    // const uint lightTriCount = gScene.lightCollection.getActiveTriangleCount();
    // if (lightTriCount != 0)
    // {
    //     uint id = min(uint(sampleNext1D(sg) * lightTriCount), lightTriCount - 1);
    //     TriangleLightSample ls;
    //     id = gScene.lightCollection.getActiveTriangleIndex(id);
    //     if (sampleTriangle(sd.posW, id, sampleNext2D(sg), ls))
    //     {
    //         const uint lobeTypes = bsdf.getLobes(sd);
    //         const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    //         const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    //         // if (dot(ls.dir, sd.N) <= kMinCosTheta && !hasTransmission)
    //         //     return float3(0.f);
    //         // if (dot(ls.dir, sd.N) >= -kMinCosTheta && !hasReflection)
    //         //     return float3(0.f);
    //         const float3 n = dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN;
    //         const float3 origin = computeRayOrigin(sd.posW, n);
    //         const Ray ray = Ray(origin, ls.dir, 0.f, ls.distance);
    //         if (traceVisibilityRayHW(ray))
    //         {
    //             color += bsdf.eval(sd, ls.dir, sg) * (ls.pdf > 0.f ? ls.Le / ls.pdf : float3(0.f));
    //         }
    //     }
    // }
    return bsdf.getProperties(sd).emission + color;
}

bool traceRaySSNaive(inout uint2 hitPix, const float3 rayOrigin, const float3 rayEnd, uint2 screen)
{
    float3 pos = rayOrigin;
    float3 step = (rayEnd - rayOrigin) / StepSize;
    float4x4 cpm = gScene.camera.getViewProj();
    bool hitOnce = false;
    bool intersect = false;
    float2 uv = float2(0.0);
    uint2 prevPix = uint2(0u);
    for (uint i = 0; i < StepSize * 2; i++)
    {
        if (i == StepSize)
            break;
        float4 clip = mul(cpm, float4(pos, 1.0));

        uv = float2((clip.x / clip.w) * 0.5 + 0.5, (-clip.y / clip.w) * 0.5 + 0.5);
        uint2 pix = uint2(uv.x * screen.x, uv.y * screen.y);

        intersect = checkIntersect(clip.z, gDepth[pix]);
        hitOnce = intersect || hitOnce;
        pos = intersect ? pos - step : pos + step;
        step = intersect ? step * 0.5 : step;

        if (isSamePix(pix, prevPix))
        {
            hitPix = pix;
            return intersect;
        }
        prevPix = pix;
    }
    return hitOnce;
}

float3 tracePath(uint2 pixel, uint2 screen)
{
    float3 outColor = float3(0.0f);
    const float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let bsdf = gScene.materials.getBSDF(sd, lod);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        float3 rayorigin = sd.computeNewRayOrigin();
        outColor += evalPrimaryRay(sd, bsdf, sg);
    }
    else
    {
        outColor = gScene.envMap.eval(primaryRayDir);
    }
    return outColor;
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    gOutColor[pixel] = float4(tracePath(pixel, gFrameDim), 1.0);
}
