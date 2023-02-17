#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Utils.PixelStats;

static const bool kUseAlphaTest = true;

bool traceVisibilityRayHW(const Ray ray)
{
    logTraceRay(PixelStatsRayType::Visibility);
    SceneRayQuery<kUseAlphaTest> srq;
    return srq.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}

bool traceRayHW(const Ray ray, inout HitInfo hit, inout float hitT)
{
    SceneRayQuery<kUseAlphaTest> srq;
    logTraceRay(PixelStatsRayType::ClosestHit);
    return srq.traceRay(ray, hit, hitT, RAY_FLAG_NONE, 0xff);
}

