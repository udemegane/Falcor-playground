#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

// __exported importで補完が効かない
import Scene.HitInfo;
import Scene.HitInfoType;
import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;

cbuffer CB
{
    uint gFrameCount;
    uint gPRNGDimension;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW;

RWTexture2D<float4> gOutputColor;

#define is_valid(name) (is_valid_##name != 0)
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
// static const bool kDirectOnly = DIRECT_ONLY;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayMax = FLT_MAX;

// shadow ray strcuture
struct ShadowRayData
{
    bool visible;
}

// scatter ray structure
struct ScatterRayData
{
    float3 radiance;
    float3 throughput;
    float3 origin;
    float3 direction;
    uint pathLength;
    bool terminated;

    SampleGenerator sg;

    __init(SampleGenerator sg)
    {
        this.sg = sg;

        this.terminated = false;
        this.pathLength = 0;
        this.radiance = float3(0, 0, 0);
        this.throughput = float3(1, 1, 1);
        this.origin = float3(0, 0, 0);
        this.direction = float3(0, 0, 0);
    }
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

ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir, const ITextureSampler lod)
{
    VertexData vertexData = {};
    uint materialID = {};

// プリプロセッサかますと補完が壊れる
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
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

bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.f;
    ray.TMax = distance;

    ShadowRayData rayData;
    rayData.visible = false; // Set to true by miss shader if ray is not terminated before
    TraceRay(gScene.rtAccel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff /* instanceInclusionMask */, 1 /* hitIdx */, rayTypeCount, 1 /* missIdx */, ray, rayData);

    return rayData.visible;
}

float3 evalDirectAnalytic(const ShadingData sd, const IBSDF bsdf, SampleGenerator sg)
{
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return float3(0.f);
    const uint lightIndex = min(uint(sampleNext1D(sg) * lightCount), lightCount - 1);

    AnalyticLightSample ls;
    if (!sampleLight(sd.posW, gScene.getLight(lightIndex), sg, ls))
        return float3(0.f);

    const uint lobeTypes = bsdf.getLobes(sd);
    const bool hasReflection = lobeTypes & uint(LobeType::Reflection);
    const bool hasTransmission = lobeTypes & uint(LobeType::Transmission);
    if (dot(ls.dir, sd.N) <= kMinCosTheta && !hasTransmission)
        return float3(0.f);
    if (dot(ls.dir, sd.N) >= -kMinCosTheta && !hasReflection)
        return float3(0.f);
    const float3 n = dot(sd.faceN, ls.dir) >= 0.f ? sd.faceN : -sd.faceN;
    const float3 origin = computeRayOrigin(sd.posW, n);

    if (!traceShadowRay(origin, ls.dir, ls.distance))
        return float3(0.f);
    float invPdf = lightCount;
    return bsdf.eval(sd, ls.dir, sg) * ls.Li * invPdf;
}

void generateScatterRay(const ShadingData sd, const IBSDF bsdf, float3 rayOrigin, inout ScatterRayData rayData)
{
    BSDFSample bsdfsample;
    if (bsdf.sample(sd, rayData.sg, bsdfsample, true))
    {
        // reinitialize ray
        rayData.origin = rayOrigin;
        if (bsdfsample.isLobe(LobeType::Transmission))
        {
            rayData.origin = sd.computeNewRayOrigin(false);
        }
        rayData.direction = bsdfsample.wo;
        rayData.throughput *= bsdfsample.weight;
        // rossian rourette
        if (!any(rayData.throughput > 0.f))
            rayData.terminated = true;
    }
    else
    {
        // これないとenvmapの参照が増えておかしなことに
        rayData.terminated = true;
    }
}

float3 evalPrimaryRay(const ShadingData sd, const IBSDF bsdf, inout SampleGenerator sg)
{
    return bsdf.getProperties(sd).emission + evalDirectAnalytic(sd, bsdf, sg);
}

float3 evalScatterRayAll(inout ScatterRayData rayData)
{

    for (uint depth = 0; depth <= kMaxBounces && !rayData.terminated; depth++)
    {
        RayDesc ray;
        ray.TMin = 0.f;
        ray.TMax = kRayMax;
        ray.Origin = rayData.origin;
        ray.Direction = rayData.direction;
        // uint
        TraceRay(gScene.rtAccel, 0, 0xff, 0, rayTypeCount, 0, ray, rayData);
    }
    float3 lr = rayData.radiance;
    return lr;
}

void handleHit(const HitInfo hit, inout ScatterRayData rayData)
{
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = loadShadingData(hit, rayData.origin, rayData.direction, lod);
    let bsdf = gScene.materials.getBSDF(sd, lod);
    float3 rayOrigin;

    //  eval hit-point emission contribution except for analytic light
    //  and do next event estimation with analytic light
    rayData.radiance += rayData.throughput * (bsdf.getProperties(sd).emission);
    if (rayData.pathLength >= kMaxBounces)
    {
        rayData.terminated = true;
        return;
    }
    rayData.radiance += rayData.throughput * evalDirectAnalytic(sd, bsdf, rayData.sg);
    if (hit.getType() == HitType::Curve)
    {
        // For curves, we set the new origin at the sphere center.
        rayOrigin = sd.posW - sd.curveRadius * sd.N;
    }
    else
    {
        rayOrigin = sd.computeNewRayOrigin();
    }
    generateScatterRay(sd, bsdf, rayOrigin, rayData);
    if (rayData.terminated == false)
        rayData.pathLength++;
}

// raytracing main function
float3 tracePath(uint2 pixel, uint2 screen)
{
    float3 outputColor = float3(0.f);

    const float3 primaryRayDir = getPrimaryRayDir(pixel, screen, gScene.camera);
    const float3 primaryRayOrigin = gScene.camera.getPosition();

    const HitInfo hit = HitInfo(gVBuffer[pixel]);
    if (hit.isValid())
    {
        const bool isCurveHit = hit.getType() == HitType::Curve;
        let lod = ExplicitLodTextureSampler(0.f);

        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);

        let bsdf = gScene.materials.getBSDF(sd, lod);
        SampleGenerator sg = SampleGenerator(pixel, gFrameCount);
        for (uint i = 0; i < gPRNGDimension; i++)
            sampleNext1D(sg);

        float3 rayOrigin = sd.computeNewRayOrigin();
        // curve primitive消した

        outputColor += evalPrimaryRay(sd, bsdf, sg);

        ScatterRayData rayData = ScatterRayData(sg);
        generateScatterRay(sd, bsdf, rayOrigin, rayData);
        outputColor += evalScatterRayAll(rayData);
    }
    else
    {
        outputColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }
    return outputColor;
}

// hardware ray tracing shaders

[shader("miss")]
void scatterMiss(inout ScatterRayData rayData)
{
    // Ray missed the scene. Mark the ray as terminated.
    rayData.terminated = true;

    // Add contribution from distant light (env map) in this direction.
    if (kUseEnvLight && (kComputeDirect || rayData.pathLength > 0))
    {
        float3 Le = gScene.envMap.eval(WorldRayDirection());
        rayData.radiance += rayData.throughput * Le;
    }
}

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    // The miss shader is executed if the ray misses all geometry. Mark as visible.
    rayData.visible = true;
}

//
// Shader entry points for TriangleMesh hit groups.
//

[shader("anyhit")]
void scatterTriangleMeshAnyHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
        IgnoreHit();
}

[shader("closesthit")]
void scatterTriangleMeshClosestHit(inout ScatterRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    handleHit(HitInfo(triangleHit), rayData);
}

[shader("anyhit")]
void shadowTriangleMeshAnyHit(inout ShadowRayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f))
        IgnoreHit();
}

//
// Shader entry points for DisplacedTriangleMesh hit groups.
//

[shader("intersection")]
void displacedTriangleMeshIntersection()
{
    const Ray ray = Ray(WorldRayOrigin(), WorldRayDirection(), RayTMin(), RayTCurrent());
    DisplacedTriangleMeshIntersector::Attribs attribs;
    float t;
    if (DisplacedTriangleMeshIntersector::intersect(ray, getGeometryInstanceID(), PrimitiveIndex(), attribs, t))
    {
        ReportHit(t, 0, attribs);
    }
}

[shader("closesthit")]
void scatterDisplacedTriangleMeshClosestHit(inout ScatterRayData rayData, DisplacedTriangleMeshIntersector::Attribs attribs)
{
    DisplacedTriangleHit displacedTriangleHit;
    displacedTriangleHit.instanceID = getGeometryInstanceID();
    displacedTriangleHit.primitiveIndex = PrimitiveIndex();
    displacedTriangleHit.barycentrics = attribs.barycentrics;
    displacedTriangleHit.displacement = attribs.displacement;
    handleHit(HitInfo(displacedTriangleHit), rayData);
}

//
// Shader entry points for Curve hit groups.
//

[shader("intersection")]
void curveIntersection()
{
    const Ray ray = Ray(WorldRayOrigin(), WorldRayDirection(), RayTMin(), RayTCurrent());
    CurveIntersector::Attribs attribs;
    float t;
    if (CurveIntersector::intersect(ray, getGeometryInstanceID(), PrimitiveIndex(), attribs, t))
    {
        ReportHit(t, 0, attribs);
    }
}

[shader("closesthit")]
void scatterCurveClosestHit(inout ScatterRayData rayData, CurveIntersector::Attribs attribs)
{
    CurveHit curveHit;
    curveHit.instanceID = getGeometryInstanceID();
    curveHit.primitiveIndex = PrimitiveIndex();
    curveHit.barycentrics = attribs.barycentrics;
    handleHit(HitInfo(curveHit), rayData);
}

//
// Shader entry points for SDFGrid hit groups.
//

[shader("intersection")]
void sdfGridIntersection()
{
    const Ray ray = Ray(WorldRayOrigin(), WorldRayDirection(), RayTMin(), RayTCurrent());
    SDFGridHitData sdfGridHitData;
    float t;
    if (SDFGridIntersector::intersect(ray, getGeometryInstanceID(), PrimitiveIndex(), sdfGridHitData, t))
    {
        ReportHit(t, 0, sdfGridHitData);
    }
}

[shader("closesthit")]
void scatterSdfGridClosestHit(inout ScatterRayData rayData, SDFGridHitData sdfGridHitData)
{
    SDFGridHit sdfGridHit;
    sdfGridHit.instanceID = getGeometryInstanceID();
    sdfGridHit.hitData = sdfGridHitData;
    handleHit(HitInfo(sdfGridHit), rayData);
}

//
// Shader entry point for ray generation shader.
//

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;

    float3 color = tracePath(pixel, frameDim);

    gOutputColor[pixel] = float4(color, 1.f);
}
