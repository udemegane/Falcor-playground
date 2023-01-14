#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSamplerHelpers;

cbuffer CB
{
    uint gFrameCount;
    uint gPRNGDimention;
}

Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float4> gMVec;

RWTexture2D<float4> gOutColor;

#define is_valid(name) (is_valid_##name != 0)
static const uint kRISSampleNums;
static const bool kUseTemporalReuse;
static const bool kUseSpatialReuse;

struct ShadowRayData
{
    bool visible;
}

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

bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = FLT_MAX;
    ShadowRayData rayData = { false };
    TraceRay(gScene.rtAccel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff, 1, rayTypeCount, 1, ray, rayData);
    return rayData.visible;
}
