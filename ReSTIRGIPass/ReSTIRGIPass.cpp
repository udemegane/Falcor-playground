/***************************************************************************
 # Copyright (c) 2023, udemegane All rights reserved.
 **************************************************************************/
#include "ReSTIRGIPass.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

using namespace Falcor;

namespace
{
const std::string kReflectTypesFile = "RenderPasses/ReSTIRGIPass/ReflectTypes.cs.slang";
const std::string kInitialSamplingFile = "RenderPasses/ReSTIRGIPass/PrepareReservoir.cs.slang";
const std::string kTemporalSamplingFile = "RenderPasses/ReSTIRGIPass/TemporalResampling.cs.slang";
const std::string kSpatialSamplingFile = "RenderPasses/ReSTIRGIPass/SpatialResampling.cs.slang";
const std::string kFinalShadingFile = "RenderPasses/ReSTIRGIPass/EvaluateSample.cs.slang";
const std::string kShaderModel = "6_5";

const std::string kInputVBuffer = "vBuffer";
const std::string kInputMotionVector = "motionVector";
const std::string kInputDepth = "depth";
const std::string kInputNoise = "noiseTex";
const std::string kInputDirectLighting = "directLighting";
const std::string kInputDiffuseReflectance = "diffuseReflectance";
const std::string kInputSpecularReflectance = "specularReflectance";

const std::string kDiffuseReflectanceTexName = "gDiffuseReflectance";
const std::string kSpecularReflectanceTexName = "gSpecularReflectance";

const std::string kSecondaryRayLaunchProbability = "secondaryRayLaunchProbability";
const std::string kRussianRouletteProbability = "russianRouletteProbability";
const std::string kUseImportanceSampling = "useImportanceSampling";
const std::string kUseInfiniteBounces = "useInfiniteBounces";
const std::string kMaxBounce = "maxBounce";
const std::string kExcludeEnvMapEmissiveFromRIS = "analyticOnly";
const std::string kUseHalfResolutionGI = "halfResolution";

const std::string kUseTemporalResampling = "useTemporalResampling";
const std::string kTemporalReservoirSize = "temporalReservoirSize";

const std::string kUseSpatialResampling = "useSpatialResampling";
const std::string kSpatialReservoirSize = "spatialReservoirSize";
const std::string kSpatialResamplingRadius = "spatialResamplingRadius";
const std::string kSpatialNeighborsCount = "spatialNeighborsCount";
const std::string kDoVisibilityTestEachSamples = "doVisibilityTestEachSamples";

const std::string kEvalDirectLighting = "evalDirectLighting";
const std::string kShowVisibilityPointLi = "showVisibilityPointLi";
const std::string kSplitView = "splitView";

const Falcor::ChannelList kInputChannels = {
    {kInputVBuffer, "gVBuffer", "Visibility Buffer"},
    {kInputMotionVector, "gMotionVector", "Motion Vector"},
    {kInputDepth, "gDepth", "Depth"},
    {kInputDirectLighting, "gDirectLighting", "Radiance from Direct Lighting", true},
    {kInputDiffuseReflectance, kDiffuseReflectanceTexName, "Diffuse Reflectance on Visibility Points", true},
    {kInputSpecularReflectance, kSpecularReflectanceTexName, "Specular Reflectance on Visibility Points", true},
    // {kInputNoise, "gNoiseTex", "Noise Texture", true},
};

const Falcor::ChannelList kOutputChannels = {
    {"color", "gColor", "Color", true, ResourceFormat::RGBA32Float},
    {"environment", "gEnvColor", "Color", true, ResourceFormat::RGBA32Float},
    {"diffuseRadianceHitDist", "gDiffuseRadiance", "", true, ResourceFormat::RGBA32Float},
    {"diffuseReflectance", "gDiffuseReflectance", "", true, ResourceFormat::RGBA32Float},
    {"specularRadianceHitDist", "gSpecularRadiance", "", true, ResourceFormat::RGBA32Float},
    {"specularReflectance", "gSpecularReflectance", "", true, ResourceFormat::RGBA32Float},
};

} // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ReSTIRGIPass>();
}

ReSTIRGIPass::ReSTIRGIPass(std::shared_ptr<Device> pDevice, const Dictionary& dict) : RenderPass(std::move(pDevice))
{
    std::random_device seed_gen;
    mEngine.seed(seed_gen());

    parseDictionary(dict);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_DEFAULT);
    if (!mpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
        logError("Inline Raytracing is not supported on this device.");
}

ReSTIRGIPass::SharedPtr ReSTIRGIPass::create(std::shared_ptr<Device> pDevice, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ReSTIRGIPass(std::move(pDevice), dict));
    return pPass;
}

Dictionary ReSTIRGIPass::getScriptingDictionary()
{
    Dictionary d;
    d[kSecondaryRayLaunchProbability] = mStaticParams.mSecondaryRayLaunchProbability;
    d[kRussianRouletteProbability] = mStaticParams.mRussianRouletteProbability;
    d[kUseImportanceSampling] = mStaticParams.mUseImportanceSampling;
    d[kUseInfiniteBounces] = mStaticParams.mUseInfiniteBounces;
    d[kMaxBounce] = mStaticParams.mMaxBounces;
    d[kUseTemporalResampling] = mStaticParams.mTemporalResampling;
    d[kTemporalReservoirSize] = mStaticParams.mTemporalReservoirSize;
    d[kUseSpatialResampling] = mStaticParams.mSpatialResampling;
    d[kSpatialReservoirSize] = mStaticParams.mSpatialReservoirSize;
    d[kSpatialResamplingRadius] = mStaticParams.mSampleRadius;
    d[kSpatialNeighborsCount] = mStaticParams.mSpatialNeighborsCount;
    d[kDoVisibilityTestEachSamples] = mStaticParams.mDoVisibilityTestEachSamples;
    d[kEvalDirectLighting] = mStaticParams.mEvalDirect;
    d[kShowVisibilityPointLi] = mStaticParams.mShowVisibilityPointLi;
    d[kSplitView] = mStaticParams.mSplitView;
    d[kExcludeEnvMapEmissiveFromRIS] = mStaticParams.mExcludeEnvMapEmissiveFromRIS;
    d[kUseHalfResolutionGI] = mStaticParams.mUseHalfResolutionGI;

    return d;
}

void ReSTIRGIPass::parseDictionary(const Dictionary& dict)
{
    for (const auto& [k, v] : dict)
    {
        if (k == kSecondaryRayLaunchProbability)
        {
            mStaticParams.mSecondaryRayLaunchProbability = v;
        }
        else if (k == kRussianRouletteProbability)
        {
            mStaticParams.mRussianRouletteProbability = v;
        }
        else if (k == kUseImportanceSampling)
        {
            mStaticParams.mUseImportanceSampling = v;
        }
        else if (k == kUseInfiniteBounces)
        {
            mStaticParams.mUseInfiniteBounces = v;
        }
        else if (k == kMaxBounce)
        {
            mStaticParams.mMaxBounces = v;
        }
        else if (k == kUseTemporalResampling)
        {
            mStaticParams.mTemporalResampling = v;
        }
        else if (k == kTemporalReservoirSize)
        {
            mStaticParams.mTemporalReservoirSize = v;
        }
        else if (k == kUseSpatialResampling)
        {
            mStaticParams.mSpatialResampling = v;
        }
        else if (k == kSpatialReservoirSize)
        {
            mStaticParams.mSpatialReservoirSize = v;
        }
        else if (k == kSpatialResamplingRadius)
        {
            mStaticParams.mSampleRadius = v;
        }
        else if (k == kSpatialNeighborsCount)
        {
            mStaticParams.mSpatialNeighborsCount = v;
        }
        else if (k == kDoVisibilityTestEachSamples)
        {
            mStaticParams.mDoVisibilityTestEachSamples = v;
        }
        else if (k == kEvalDirectLighting)
        {
            mStaticParams.mEvalDirect = v;
        }
        else if (k == kShowVisibilityPointLi)
        {
            mStaticParams.mShowVisibilityPointLi = v;
        }
        else if (k == kSplitView)
        {
            mStaticParams.mSplitView = v;
        }
        else if (k == kExcludeEnvMapEmissiveFromRIS)
        {
            mStaticParams.mExcludeEnvMapEmissiveFromRIS = v;
        }
        else if (k == kUseHalfResolutionGI)
        {
            mStaticParams.mUseHalfResolutionGI = v;
        }
    }
}

RenderPassReflection ReSTIRGIPass::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReSTIRGIPass::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    mFrameCount = 0;
    mpScene = pScene;
    mpReflectTypes = nullptr;
    mpInitialSamplingPass = nullptr;
    mpTemporalResamplingPass = nullptr;
    mpSpatialResamplingPass = nullptr;
    mpFinalShadingPass = nullptr;
    if (mpScene)
    {
    }
}

void ReSTIRGIPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    const auto& pVBuffer = renderData.getTexture(kInputVBuffer);
    //    const auto& pNormal = renderData.getTexture(kInputNormal);
    const auto& pMVec = renderData.getTexture(kInputMotionVector);

    const auto& pDepth = renderData.getTexture(kInputDepth);
    mFrameDim = uint2(pVBuffer->getWidth(), pVBuffer->getHeight());

    if (!mpScene)
    {
        clearRenderPassChannels(pRenderContext, kOutputChannels, renderData);
        return;
    }

    auto& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    bool lightingChanged = false;

    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::RenderSettingsChanged))
    {
        lightingChanged = true;
    }

    if (mpScene->useEmissiveLights())
    {
        if (!mpEmissiveLightSampler)
        {
            const auto& pLights = mpScene->getLightCollection(pRenderContext);
            FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
            FALCOR_ASSERT(!mpEmissiveLightSampler);
            mpEmissiveLightSampler = LightBVHSampler::create(pRenderContext, mpScene);
            lightingChanged = true;
        }
    }
    else
    {
        mpEmissiveLightSampler = nullptr;
        lightingChanged = true;
        // TODO
    }

    if (mpScene->useEnvLight())
    {
        if (!mpEnvMapSampler)
        {
            mpEnvMapSampler = EnvMapSampler::create(mpDevice, mpScene->getEnvMap());
            lightingChanged = true;
            //
        }
    }
    else
    {
        mpEnvMapSampler = nullptr;
        lightingChanged = true;
        // TODO
    }
    if (mpEmissiveLightSampler)
    {
        mpEmissiveLightSampler->update(pRenderContext);
    }

    prepareResources(pRenderContext, renderData);
    initialSampling(pRenderContext, renderData, pVBuffer, pDepth, pMVec);
    if (mStaticParams.mUseHalfResolutionGI)
        temporalResamplingHalfRes(pRenderContext, renderData);
    finalShading(pRenderContext, renderData, pVBuffer, pDepth);
    endFrame();
}

Program::DefineList ReSTIRGIPass::getStaticDefines(const RenderData& renderData)
{
    Program::DefineList defines;
    defines.add("P_RR", std::to_string(mStaticParams.mRussianRouletteProbability));
    defines.add("P_SECONDARY_RR", std::to_string(mStaticParams.mSecondaryRayLaunchProbability));
    defines.add("USE_IMPORTANCE_SAMPLING", mStaticParams.mUseImportanceSampling ? "1" : "0");
    defines.add("USE_ENVLIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    defines.add("USE_INFINITE_BOUNCES", mStaticParams.mUseInfiniteBounces ? "1" : "0");
    defines.add("MAX_BOUNCES", std::to_string(mStaticParams.mMaxBounces));
    defines.add("EXCLUDE_ENV_AND_EMISSIVE_FROM_RIS", mStaticParams.mExcludeEnvMapEmissiveFromRIS ? "1" : "0");
    defines.add("USE_HARF_RESOLUTION", mStaticParams.mUseHalfResolutionGI ? "1" : "0");

    defines.add("USE_TEMPORAL_RESAMPLING", mStaticParams.mTemporalResampling ? "1" : "0");
    defines.add("TEMPORAL_RESERVOIR_SIZE", std::to_string(mStaticParams.mTemporalReservoirSize));
    defines.add("USE_SPATIAL_RESAMPLING", mStaticParams.mSpatialResampling ? "1" : "0");
    //    defines.add("USE_MIS", mStaticParams.mUseMIS?"1":"0");
    defines.add("SPATIAL_NEIGHBORHOOD_COUNTS", std::to_string(mStaticParams.mSpatialNeighborsCount));
    defines.add("SPATIAL_RESAMPLING_RADIUS", std::to_string(mStaticParams.mSampleRadius));
    defines.add("SPATIAL_RESERVOIR_SIZE", std::to_string(mStaticParams.mSpatialReservoirSize));
    defines.add("DO_VISIBILITY_TEST_EACH_SAMPLES", mStaticParams.mDoVisibilityTestEachSamples ? "1" : "0");

    defines.add("EVAL_DIRECT", mStaticParams.mEvalDirect ? "1" : "0");
    defines.add("SHOW_VISIBILITY_POINT_LI", mStaticParams.mShowVisibilityPointLi ? "1" : "0");
    defines.add("DEBUG_SPLIT_VIEW", mStaticParams.mSplitView ? "1" : "0");
    const auto& diffuseReflectance = renderData.getTexture(kInputDiffuseReflectance);
    const auto& specularReflectance = renderData.getTexture(kInputSpecularReflectance);
    const auto& directLighting = renderData.getTexture(kInputDirectLighting);
    const bool readyDirectLighting = (directLighting != nullptr) && (specularReflectance != nullptr) && (diffuseReflectance != nullptr);
    defines.add("READY_REFLECTANCE", readyDirectLighting ? "1" : "0");
    if (mpEmissiveLightSampler)
        defines.add(mpEmissiveLightSampler->getDefines());
    // if (mpScene)
    //     defines.add(mpScene->getSceneDefines());
    return defines;
}

void ReSTIRGIPass::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpReflectTypes)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addTypeConformances(mpScene->getMaterialSystem()->getTypeConformances());
        desc.addShaderLibrary(kReflectTypesFile).setShaderModel(kShaderModel).csEntry("main");

        auto defines = mpScene->getSceneDefines();
        defines.add(getStaticDefines(renderData));
        mpReflectTypes = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpReflectTypes);
    mpReflectTypes->getProgram()->addDefines(getStaticDefines(renderData));
    auto rootVar = mpReflectTypes->getRootVar();

    if (!mpParamsBlock)
    {
        auto reflector = mpReflectTypes->getProgram()->getReflector()->getParameterBlock("params");
        mpParamsBlock = ParameterBlock::create(mpDevice.get(), reflector);
        FALCOR_ASSERT(mpParamsBlock);
    }

    {
        auto var = mpParamsBlock->getRootVar();

        if (mpEmissiveLightSampler)
            mpEmissiveLightSampler->setShaderData(var["emissiveSampler"]);
        if (mpEnvMapSampler)
            mpEnvMapSampler->setShaderData(var["envMapSampler"]);
    }
}

void ReSTIRGIPass::initialSampling(
    RenderContext* pRenderContext,
    const RenderData& renderData,
    const Texture::SharedPtr& pVBuffer,
    const Texture::SharedPtr& pDepth,
    const Texture::SharedPtr& pMotionVector
)
{
    FALCOR_ASSERT(pVBuffer);

    if (!mpInitialSamplingPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kInitialSamplingFile).setShaderModel(kShaderModel).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        auto defines = mpScene->getSceneDefines();
        FALCOR_ASSERT(mpSampleGenerator);
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getStaticDefines(renderData));

        mpInitialSamplingPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpInitialSamplingPass);
    mpInitialSamplingPass->getProgram()->addDefines(getStaticDefines(renderData));

    auto var = mpInitialSamplingPass->getRootVar();

    if (!mpTemporalReservoirs || mGIResolutionChanged)
    {
        uint32_t reservoirCounts = mStaticParams.mUseHalfResolutionGI ? (mFrameDim.x / 2u) * (mFrameDim.y / 2u) : mFrameDim.x * mFrameDim.y;
        mpTemporalReservoirs = Buffer::createStructured(
            mpDevice.get(), var["gTemporalReservoirs"], reservoirCounts,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
        );
    }

    if (!mpIntermediateReservoirs || mGIResolutionChanged)
    {
        uint32_t reservoirCounts = mStaticParams.mUseHalfResolutionGI ? (mFrameDim.x / 2u) * (mFrameDim.y / 2u) : mFrameDim.x * mFrameDim.y;

        mpIntermediateReservoirs = Buffer::createStructured(
            mpDevice.get(), var["gIntermediateReservoirs"], reservoirCounts,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
        );
    }

    var["gTemporalReservoirs"] = mpTemporalReservoirs;
    var["gIntermediateReservoirs"] = mpIntermediateReservoirs;

    var["gVBuffer"] = pVBuffer;
    var["gDepth"] = pDepth;
    var["gMotionVector"] = pMotionVector;

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mFrameDim;
    var["CB"]["gRandUint"] = mEngine();

    FALCOR_ASSERT(mpParamsBlock);
    var["params"] = mpParamsBlock;

    {
        auto paramsVar = var["params"];

        if (mpScene->useEmissiveLights())
            FALCOR_ASSERT(mpEmissiveLightSampler);
        if (mpEmissiveLightSampler)
            mpEmissiveLightSampler->setShaderData(paramsVar["emissiveSampler"]);

        if (mpScene->useEnvLight())
            FALCOR_ASSERT(mpEnvMapSampler);
        if (mpEnvMapSampler)
            mpEnvMapSampler->setShaderData(paramsVar["envMapSampler"]);
    }

    mpSampleGenerator->setShaderData(var);

    mpScene->setRaytracingShaderData(pRenderContext, var);
    mpInitialSamplingPass->execute(pRenderContext, {mFrameDim, 1u});
}

void ReSTIRGIPass::temporalResamplingHalfRes(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpTemporalResamplingPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kTemporalSamplingFile).setShaderModel(kShaderModel).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        auto defines = mpScene->getSceneDefines();
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getStaticDefines(renderData));

        mpTemporalResamplingPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    mpTemporalResamplingPass->getProgram()->addDefines(getStaticDefines(renderData));
    auto var = mpTemporalResamplingPass->getRootVar();

    if (!mpIntermediateReservoirs)
    {
        uint32_t reservoirCounts = (mFrameDim.x / 2u) * (mFrameDim.y / 2u);
        mpIntermediateReservoirs = Buffer::createStructured(
            mpDevice.get(), var["gIntermediateReservoirs"], reservoirCounts,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
        );
    }
    if (!mpSpatialReservoirs)
    {
        uint32_t reservoirCounts = (mFrameDim.x / 2u) * (mFrameDim.y / 2u);
        mpSpatialReservoirs = Buffer::createStructured(
            mpDevice.get(), var["gSpatialReservoirs"], reservoirCounts,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
        );
    }
    var["gTemporalReservoirs"] = mpTemporalReservoirs;
    var["gIntermediateReservoirs"] = mpIntermediateReservoirs;
    var["gSpatialReservoirs"] = mpSpatialReservoirs;
    // var["gVBuffer"] = renderData.getTexture(kInputVBuffer);
    var["gMotionVector"] = renderData.getTexture(kInputMotionVector);
    uint2 harfRes = uint2(mFrameDim.x / 2u, mFrameDim.y / 2u);
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gHarfFrameDim"] = harfRes;
    var["CB"]["gRandUint"] = mEngine();

    var["gScene"] = mpScene->getParameterBlock();
    mpSampleGenerator->setShaderData(var);

    mpTemporalResamplingPass->execute(pRenderContext, {harfRes, 1u});
}

// void ReSTIRGIPass::spatialResamplingHalfRes(RenderContext* pRenderContext, const RenderData& renderData, const Texture::SharedPtr&
// pNoiseTexture)
//{
//     //    FALCOR_ASSERT();
//     if (!mpSpatialResamplingPass)
//     {
//         Program::Desc desc;
//         desc.addShaderModules(mpScene->getShaderModules());
//         desc.addShaderLibrary(kSpatialSamplingFile).setShaderModel(kShaderModel).csEntry("main");
//         desc.addTypeConformances(mpScene->getTypeConformances());
//         auto defines = mpScene->getSceneDefines();
//         FALCOR_ASSERT(mpSampleGenerator);
//         defines.add(mpSampleGenerator->getDefines());
//         defines.add(getStaticDefines());
//         mpSpatialResamplingPass = ComputePass::create(mpDevice, desc, defines, true);
//     }
//
//     FALCOR_ASSERT(mpSpatialResamplingPass);
//     mpSpatialResamplingPass->getProgram()->addDefines(getStaticDefines());
//     auto var = mpSpatialResamplingPass->getRootVar();
//
//     if (!mpSpatialReservoirs)
//     {
//         uint32_t reservoirCounts = mFrameDim.x * mFrameDim.y;
//         mpSpatialReservoirs = Buffer::createStructured(
//             mpDevice.get(), var["gSpatialReservoirs"], reservoirCounts,
//             ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
//         );
//     }
//     FALCOR_ASSERT(mpIntermediateReservoirs);
//     FALCOR_ASSERT(mpSpatialReservoirs);
//     //    if(!mpSpatialReservoirs){
//     //        uint32_t reservoirCounts=mFrameDim.x*mFrameDim.y;
//     //        mpSpatialReservoirs = Buffer::createStructured(
//     //            mpDevice.get(), var["gSpatialReservoirs"], reservoirCounts, ResourceBindFlags::ShaderResource|
//     //            ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
//     //        );
//     //    }
//      var["gTemporalReservoirs"] = mpTemporalReservoirs;
//     var["gSpatialReservoirs"] = mpSpatialReservoirs;
//     var["gIntermediateReservoirs"] = mpIntermediateReservoirs;
//
//     var["gNoise"] = pNoiseTexture;
//
//     var["CB"]["gFrameCount"] = mFrameCount;
//     var["CB"]["gFrameDim"] = mFrameDim;
//     var["CB"]["gNoiseTexDim"] = mNoiseDim;
//
//     var["gScene"] = mpScene->getParameterBlock();
//
//     mpSampleGenerator->setShaderData(var);
//     mpScene->setRaytracingShaderData(pRenderContext, var);
//     mpSpatialResamplingPass->execute(pRenderContext, {mFrameDim, 1u});
// }

void ReSTIRGIPass::finalShading(
    RenderContext* pRenderContext,
    const RenderData& renderData,
    const Texture::SharedPtr& pVBuffer,
    const Texture::SharedPtr& pDepth
)
{
    if (!mpFinalShadingPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kFinalShadingFile).setShaderModel(kShaderModel).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());
        FALCOR_ASSERT(mpSampleGenerator);
        auto defines = mpScene->getSceneDefines();
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getStaticDefines(renderData));
        defines.add(getValidResourceDefines(kOutputChannels, renderData));

        mpFinalShadingPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    mpFinalShadingPass->getProgram()->addDefines(getValidResourceDefines(kOutputChannels, renderData));
    mpFinalShadingPass->getProgram()->addDefines(getStaticDefines(renderData));
    auto var = mpFinalShadingPass->getRootVar();
    FALCOR_ASSERT(mpSpatialReservoirs);

    //    var["gInitSamples"] = mpInitialSamples;

    var["gIntermediateReservoirs"] = mStaticParams.mUseHalfResolutionGI ? mpSpatialReservoirs : mpIntermediateReservoirs;
    // var["gNoise"] = pNoiseTexture;
    var["gVBuffer"] = pVBuffer;
    var[kDiffuseReflectanceTexName] = renderData.getTexture(kInputDiffuseReflectance);
    var[kSpecularReflectanceTexName] = renderData.getTexture(kInputSpecularReflectance);
    var["gDirectLighting"] = renderData.getTexture(kInputDirectLighting);

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mFrameDim;
    // var["CB"]["gNoiseTexDim"] = mNoiseDim;
    var["CB"]["gRandUint"] = mEngine();

    var["gScene"] = mpScene->getParameterBlock();

    auto bind = [&](const ChannelDesc& channel)
    {
        Texture::SharedPtr pTex = renderData.getTexture(channel.name);
        var[channel.texname] = pTex;
    };
    for (const auto& channel : kOutputChannels)
        bind(channel);

    mpSampleGenerator->setShaderData(var);
    //    if(mpEmissiveLightSampler)
    //        mpEmissiveLightSampler->setShaderData(var);
    //    if(mpEnvMapSampler)
    //        mpEnvMapSampler->setShaderData(var);
    mpScene->setRaytracingShaderData(pRenderContext, var);

    mpFinalShadingPass->execute(pRenderContext, {mFrameDim, 1u});
}

void ReSTIRGIPass::endFrame()
{
    if (mStaticParams.mUseHalfResolutionGI)
        mpTemporalReservoirs.swap(mpSpatialReservoirs);
    else
        mpTemporalReservoirs.swap(mpIntermediateReservoirs);
    mGIResolutionChanged = false;
    mFrameCount++;
}

void ReSTIRGIPass::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    mGIResolutionChanged = widget.checkbox("Use Harf Resolution (WIP)", mStaticParams.mUseHalfResolutionGI);
    dirty |= mGIResolutionChanged;
    dirty |= widget.var("Secondary Ray Probability", mStaticParams.mSecondaryRayLaunchProbability, 0.f, 1.f);
    dirty |= widget.var("Russian Roulette Probability", mStaticParams.mRussianRouletteProbability, 0.f, 1.f);
    dirty |= widget.checkbox("Use Multi Bounces", mStaticParams.mUseInfiniteBounces);
    if (mStaticParams.mUseInfiniteBounces)
        dirty |= widget.var("Max Bounces", mStaticParams.mMaxBounces, 0u, 30u);
    dirty |= widget.checkbox("Exclude EnvMap and Emissive mesh from RIS", mStaticParams.mExcludeEnvMapEmissiveFromRIS);

    if (Gui::Group temporalGroup = widget.group("Temporal Resampling", true))
    {
        dirty |= temporalGroup.checkbox("Use Temporal Resampling", mStaticParams.mTemporalResampling);
        if (mStaticParams.mTemporalResampling)
        {
            dirty |= temporalGroup.var("Reservoir Size", mStaticParams.mTemporalReservoirSize, 1u, 50u);
        }
    }
    if (auto spatialGroup = widget.group("Spatial Resampling", true))
    {
        dirty |= spatialGroup.checkbox("Use Spatial Resampling", mStaticParams.mSpatialResampling);
        if (mStaticParams.mSpatialResampling)
        {
            dirty |= spatialGroup.var("Neighbors Count", mStaticParams.mSpatialNeighborsCount, 1u, 50u);
            dirty |= spatialGroup.var("Sample Radius", mStaticParams.mSampleRadius, 1u, 500u);
            dirty |= spatialGroup.var("Reservoir Size", mStaticParams.mSpatialReservoirSize, 1u, 500u);
        }
    }

    if (dirty)
    {
        mOptionsChanged = true;
    }
}
