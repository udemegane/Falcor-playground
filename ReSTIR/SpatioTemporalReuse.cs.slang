#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Materials.StandardMaterial;
import Rendering.Utils.PixelStats;
import Rendering.Lights.LightHelpers;
import Reservoir;

cbuffer PerFrameCB
{
    uint gFrameCount;
    uint2 gScreen;
}

// Input
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;
Texture2D<float2> gMVec;
Texture2D<float> gDepth;
StructuredBuffer<RISReservoir> intermediateReservoir;
// InOut
RWStructuredBuffer<RISReservoir> prevFrameReservoir;
// Output
RWTexture2D<float4> gOutputColor;

#define is_valid(name) (is_valid_##name != 0)

static const uint kSpatialNeigborsNum = 5;
static const float kSampleRadius = 30.0;
static const bool kUseReSTIR = USE_RESTIR;
static const bool kUseTemporalReuse = USE_TEMPORAL_REUSE;
static const uint kTemporalReuseMaxM = TEMPORAL_REUSE_MAX_M;
static const bool kUseAutoSetMaxM = USE_AUTO_SET_MAX_M;
static const bool kUseSpatialReuse = USE_SPATIAL_REUSE;

int getPrevFramePos1D(uint2 pixelPos, uint2 screen)
{
    uint2 prevPixPos = pixelPos + uint2(screen * gMVec[pixelPos]);
    return prevPixPos.x + screen.x * prevPixPos.y;
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

ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, const ITextureSampler lod)
{
    VertexData vertexData = {};
    uint materialID = {};

// プリプロセッサかますと補完が壊れる
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        gScene;
        const TriangleHit th = hit.getTriangleHit();
        vertexData = gScene.getVertexData(th);
        materialID = gScene.getMaterialID(th.instanceID);
    }
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH)
    if (hit.getType() == HitType::DisplacedTriangle)
    {
        const DisplacedTriangleHit dth = hit.getDisplacedTriangleHit();
        vertexData = gScene.getVertexData(dth, -rayDir);
        materialID = gScene.getMaterialID(dth.instanceID);
    }
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
    if (hit.getType() == HitType::Curve)
    {
        const CurveHit ch = hit.getCurveHit();
        vertexData = gScene.getVertexDataFromCurve(ch);
        materialID = gScene.getMaterialID(ch.instanceID);
    }
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_SDF_GRID)
    if (hit.getType() == HitType::SDFGrid)
    {
        const SDFGridHit sh = hit.getSDFGridHit();
        vertexData = gScene.getVertexDataFromSDFGrid(sh, rayOrigin, rayDir);
        materialID = gScene.getMaterialID(sh.instanceID);
    }
#endif

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CUSTOM)
    {
    }
#endif
    ShadingData sd = gScene.materials.prepareShadingData(vertexData, materialID, -rayDir, lod);
    return sd;
}

bool traceVisibilityRay(const Ray ray)
{
    logTraceRay(PixelStatsRayType::Visibility);
    SceneRayQuery<true> srq;
    return srq.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
}

void finalShading(uint2 pixel, uint2 screen)
{
    float3 outColor = float3(0.f);
    const float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        let lod = ExplicitLodTextureSampler(0.f);
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
        let bsdf = gScene.materials.getBSDF(sd, lod);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        // for (uint i = 0; i < gPRNGDimension; i++)
        //     sampleNext1D(sg);

        float3 rayOrigin = sd.computeNewRayOrigin();
        // curve primitive消した

        outColor += bsdf.getProperties(sd).emission + spatioTemporalTrace(pixel, screen, sd, bsdf, sg);
    }

    gOutputColor[pixel] = float4(outColor, 1.0f);
}

float3 spatioTemporalTrace(uint2 pixel, uint2 screen, ShadingData sd, IBSDF bsdf, SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (kUseReSTIR)
    {
        RISReservoir r = intermediateReservoir[pixel.x + gScreen.x * pixel.y];
        float rand = sampleNext1D(sg);
        if (kUseTemporalReuse)
        {
            RISReservoir rprev = prevFrameReservoir[getPrevFramePos1D(pixel, gScreen)];

            // clamp previous frame reservoir length.
            uint max = kUseAutoSetMaxM ? lightCount / 4 : kTemporalReuseMaxM;
            if (rprev.M > r.M * max)
            {
                float ratio = ((float)max * r.M / rprev.M);
                rprev.wSum *= ratio;
                rprev.M = max * r.M;
            }
            RISReservoir res = RISReservoir();
            res.update(r.currentSampleId, r.wSum, r.targetPdfSample, randSimple((r.wSum, rprev.targetPdfSample.x)));
            res.update(rprev.currentSampleId, rprev.wSum, rprev.targetPdfSample, randSimple((rprev.wSum, r.targetPdfSample.y)));
            res.M = r.M + rprev.M;
            r = res;
        }
        if (kUseSpatialReuse)
        {
            for (uint i = 0; i < kSpatialNeigborsNum; i++)
            {
                float radius = kSampleRadius * rand;
                float angle = 2.0f * M_PI * frac(sin(gFrameCount * rand));
                uint2 neighborPos = {
                    pixel.x + uint(radius * cos(angle)),
                    pixel.y + uint(radius * sin(angle))
                };

                rand = randSimple(((float)neighborPos.x / rand, (float)neighborPos.y / rand));
            }
            // TODO: combine reservoirs;
        }
        prevFrameReservoir[pixel.x + gScreen.x * pixel.y] = r; // for next frame;
        uint lightIndex = r.currentSampleId;
        float invPdf = r.getInvPDF();
        AnalyticLightSample ls;
        const uint lobeTypes = bsdf.getLobes(sd);
        if (dot(ls.dir, sd.N) <= kMinCosTheta && !(lobeTypes & (uint)LobeType::Transmission))
            return float3(0.f);
        if (dot(ls.dir, sd.N) >= -kMinCosTheta && !(lobeTypes & (uint)LobeType::Reflection))
            return float3(0.f);
        float3 n = dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN;
        float3 origin = computeRayOrigin(sd.posW, n);
        Ray ray = Ray(origin, ls.dir, 0.0f, ls.distance);
        if (traceVisibilityRay(ray))
        {
            return r.targetPdfSample * invPdf;
        }
        else
        {
            return float3(0.f);
        }
    }
    else
    {
        // TODO: impl random pdf sampling.
        return float3(0.f);
    }
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    finalShading(dispatchThreadId.xy, gScreen);
}
