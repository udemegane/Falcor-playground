/***************************************************************************
 # Copyright (c) 2023, udemegane All rights reserved.
 **************************************************************************/

#include "Scene/SceneDefines.slangh"

__exported import Scene.HitInfo;
__exported import Scene.HitInfoType;
import Scene.RaytracingInline;

import Utils.Debug.PixelDebug;
import Rendering.Utils.PixelStats;

/**
    \param[in] ray
    \param[out] hit
    \param[out] hitT
    \return True if ray get a hit.
*/

bool traceRayInline(const Ray ray, inout HitInfo hit, inout float hitT)
{
    logTraceRay(PixelStatsRayType::ClosestHit);
    SceneRayQuery<true> srq;
    return srq.traceRay(ray, hit, hitT, RAY_FLAG_NONE, 0xff);
}

/**
    \param[in] ray
    \return True if ray get a hit.
 */

bool traceVisibilityRay(const Ray ray)
{
    logTraceRay(PixelStatsRayType::Visibility);
    SceneRayQuery<true> srq;
    return srq.traceVisibilityRay(ray, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff);
}
