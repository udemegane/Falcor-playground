/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "ReSTIRDIPass.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

using namespace Falcor;

namespace
{
const std::string kReflectTypesFile = "RenderPasses/ReSTIRDIPass/ReflectTypes.cs.slang";
const std::string kTracePassFile = "RenderPasses/ReSTIRDIPass/PrepareReservoir.cs.slang";
const std::string kSpatioResamplingFileName = "RenderPasses/ReSTIRDIPass/FinalShading.cs.slang";

const std::string kShaderModel = "6_5";

const std::string kInputVBuffer = "vBuffer";
const std::string kInputMotionVector = "motionVecW";
const std::string kInputViewW = "viewW";
const std::string kInputDepth = "depth";
const std::string kInputNormal = "normal";

const ChannelList kInputChannels = {
    {kInputVBuffer, "gVBuffer", "Visibility buffer"},
    {kInputMotionVector, "gMVec", "world-space motion vector", true, ResourceFormat::RG32Float},
    {kInputViewW, "gViewW", "World-Space view Direction", true},
    {kInputDepth, "gDepth", "Depth buffer (NDC)", true, ResourceFormat::R32Float},
    {kInputNormal, "gNormal", "World Normal", false, ResourceFormat::RGBA32Float},
};

const Falcor::ChannelList kOutputChannels = {
    {"color", "gColor", "Estimated Radiance of Direct Lighting", true, ResourceFormat::RGBA32Float},
    {"diffuseRadiance", "gDiffuseRadiance", "", true, ResourceFormat::RGBA32Float},
    {"diffuseReflectance", "gDiffuseReflectance", "", true, ResourceFormat::RGBA32Float},
    {"specularRadiance", "gSpecularRadiance", "", true, ResourceFormat::RGBA32Float},
    {"specularReflectance", "gSpecularReflectance", "", true, ResourceFormat::RGBA32Float},
};
const char kUseImportanceSampling[] = "useImportanceSampling";
const char kRISSampleNums[] = "risSampleNums";
const char kUseReSTIR[] = "useReSTIR";
const char kTemporalReuseMaxM[] = "temporalReuseMaxM";
const char kAutoSetMaxM[] = "autoSetMaxM";
const char kUseTemporalReuse[] = "useTemporalReuse";
const char kUseSpatialReuse[] = "useSpatialReuse";
const char kSpatialRadius[] = "spatialRadius";
const char kSpatialNeighbors[] = "spatialNeighbors";
} // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ReSTIRDIPass>();
}

ReSTIRDIPass::ReSTIRDIPass(std::shared_ptr<Device> pDevice, const Dictionary& dict) : RenderPass(std::move(pDevice))
{
    parseDictionary(dict);
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_TINY_UNIFORM);
    if (!mpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
        logError("Inline Raytracing is not supported on this device.");
}

ReSTIRDIPass::SharedPtr ReSTIRDIPass::create(std::shared_ptr<Device> pDevice, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ReSTIRDIPass(std::move(pDevice), dict));
    return pPass;
}

void ReSTIRDIPass::parseDictionary(const Dictionary& dict)
{
    for (const auto& [k, v] : dict)
    {
        if (k == kTemporalReuseMaxM)
        {
            mStaticParams.mTemporalReuseMaxM = v;
        }
        else if (k == kRISSampleNums)
        {
            mStaticParams.mRISSampleNums = v;
        }
        else if (k == kUseReSTIR)
        {
            mStaticParams.mUseReSTIR = v;
        }
        else if (k == kAutoSetMaxM)
        {
            mStaticParams.mAutoSetMaxM = v;
        }
        else if (k == kUseTemporalReuse)
        {
            mStaticParams.mUseTemporalReuse = v;
        }
        else if (k == kUseSpatialReuse)
        {
            mStaticParams.mUseSpatialReuse = v;
        }
        else if (k == kSpatialRadius)
        {
            mStaticParams.mSpatialRadius = v;
        }
        else if (k == kSpatialNeighbors)
        {
            mStaticParams.mSpatialNeighbors = v;
        }
    }
}

Dictionary ReSTIRDIPass::getScriptingDictionary()
{
    Dictionary dict;
    dict[kTemporalReuseMaxM] = mStaticParams.mTemporalReuseMaxM;
    dict[kRISSampleNums] = mStaticParams.mRISSampleNums;
    dict[kAutoSetMaxM] = mStaticParams.mAutoSetMaxM;
    dict[kUseReSTIR] = mStaticParams.mUseReSTIR;
    dict[kUseTemporalReuse] = mStaticParams.mUseTemporalReuse;
    dict[kUseSpatialReuse] = mStaticParams.mUseSpatialReuse;
    dict[kSpatialRadius] = mStaticParams.mSpatialRadius;
    dict[kSpatialNeighbors] = mStaticParams.mSpatialNeighbors;
    return dict;
}

RenderPassReflection ReSTIRDIPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReSTIRDIPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    RenderPass::compile(pRenderContext, compileData);
    mFrameDim = compileData.defaultTexDims;
}

void ReSTIRDIPass::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    mFrameCount = 0;
    mpScene = pScene;
    mpIntermediateReservoir = nullptr;
    mpReflectTypes = nullptr;
    mpTracePass = nullptr;
    mpSpatialResampling = nullptr;
}

void ReSTIRDIPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    mFrameDim = renderData.getDefaultTextureDims();

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

    //====================================
    // Start Scene Light Settings
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
        if (!mpEmissiveSampler)
        {
            const auto& pLights = mpScene->getLightCollection(pRenderContext);
            FALCOR_ASSERT(pLights && pLights->getActiveLightCount(pRenderContext) > 0);
            FALCOR_ASSERT(!mpEmissiveSampler);
            mpEmissiveSampler = LightBVHSampler::create(pRenderContext, mpScene);
            lightingChanged = true;
        }
    }
    else
    {
        mpEmissiveSampler = nullptr;
        lightingChanged = true;
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
    }
    if (mpEmissiveSampler)
    {
        mpEmissiveSampler->update(pRenderContext);
    }
    // End Scene light Settings.
    //====================================

    const auto& pVBuffer = renderData.getTexture(kInputVBuffer);
    const auto& pMVec = renderData.getTexture(kInputMotionVector);
    const auto& pDepth = renderData.getTexture(kInputDepth);
    const auto& pViewW = renderData.getTexture(kInputViewW);

    prepareResources(pRenderContext, renderData);
    prepareReservoir(pRenderContext, renderData, pVBuffer, pDepth, pViewW, pMVec);
    finalShading(pRenderContext, renderData, pVBuffer, pDepth, pViewW);
    endFrame(pRenderContext, renderData);
}

Program::DefineList ReSTIRDIPass::getDefines()
{
    Program::DefineList defines;
    defines.add("USE_ENVLIGHT", mpScene->useEnvLight() ? "1" : "0");
    defines.add("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    defines.add("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    if (mpEmissiveSampler)
        defines.add(mpEmissiveSampler->getDefines());

    return defines;
}

void ReSTIRDIPass::prepareResources(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (!mpReflectTypes)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addTypeConformances(mpScene->getMaterialSystem()->getTypeConformances());
        desc.addShaderLibrary(kReflectTypesFile).setShaderModel(kShaderModel).csEntry("main");

        auto defines = mpScene->getSceneDefines();
        defines.add(getDefines());
        mpReflectTypes = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpReflectTypes);
    mpReflectTypes->getProgram()->addDefines(getDefines());
    auto rootVar = mpReflectTypes->getRootVar();

    if (!mpParamsBlock)
    {
        auto reflector = mpReflectTypes->getProgram()->getReflector()->getParameterBlock("params");
        mpParamsBlock = ParameterBlock::create(mpDevice.get(), reflector);
        FALCOR_ASSERT(mpParamsBlock);
    }

    if (!mpPrevNormal)
    {
        mpPrevNormal = Texture::create2D(
            mpDevice.get(), (uint32_t)mFrameDim.x, (uint32_t)mFrameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
    }

    {
        auto var = mpParamsBlock->getRootVar();

        if (mpEmissiveSampler)
            mpEmissiveSampler->setShaderData(var["emissiveSampler"]);
        if (mpEnvMapSampler)
            mpEnvMapSampler->setShaderData(var["envMapSampler"]);
    }
}

void ReSTIRDIPass::prepareReservoir(
    RenderContext* pRenderContext,
    const RenderData& renderData,
    const Texture::SharedPtr& vBuffer,
    const Texture::SharedPtr& depth,
    const Texture::SharedPtr& viewW,
    const Texture::SharedPtr& motionVector
)
{
    FALCOR_ASSERT(vBuffer);
    if (!mpTracePass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kTracePassFile).setShaderModel(kShaderModel).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        auto defines = mpScene->getSceneDefines();
        FALCOR_ASSERT(mpSampleGenerator);
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getDefines());

        mpTracePass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpTracePass);
    mpTracePass->getProgram()->addDefines(getDefines());

    auto var = mpTracePass->getRootVar();

    if (!mpIntermediateReservoir)
    {
        uint32_t reservoirCounts = mFrameDim.x * mFrameDim.y;
        mpIntermediateReservoir = Buffer::createStructured(
            mpDevice.get(), var["gIntermediateReservoir"], reservoirCounts,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
        );
    }
    if (!mpTemporalReservoir)
    {
        uint32_t reservoirCounts = mFrameDim.x * mFrameDim.y;
        mpTemporalReservoir = Buffer::createStructured(
            mpDevice.get(), var["gTemporalReservoir"], reservoirCounts,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None, nullptr, false
        );
    }
    var["gIntermediateReservoir"] = mpIntermediateReservoir;
    var["gTemporalReservoir"] = mpTemporalReservoir;

    var["gVBuffer"] = vBuffer;
    var["gDepth"] = depth;
    var["gViewW"] = viewW;
    var["gMotionVector"] = motionVector;
    var["gNormal"] = renderData.getTexture(kInputNormal);
    var["gPrevNormal"] = mpPrevNormal;

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mFrameDim;
    var["CB"]["isValidViewW"] = viewW == nullptr;

    FALCOR_ASSERT(mpParamsBlock);
    var["params"] = mpParamsBlock;

    {
        auto paramsVar = var["params"];

        if (mpScene->useEmissiveLights())
            FALCOR_ASSERT(mpEmissiveSampler);
        if (mpEmissiveSampler)
            mpEmissiveSampler->setShaderData(paramsVar["emissiveSampler"]);

        if (mpScene->useEnvLight())
            FALCOR_ASSERT(mpEnvMapSampler);
        if (mpEnvMapSampler)
            mpEnvMapSampler->setShaderData(paramsVar["envMapSampler"]);
    }

    var["gScene"] = mpScene->getParameterBlock();
    mpSampleGenerator->setShaderData(var);
    mpTracePass->execute(pRenderContext, {mFrameDim, 1u});
}

void ReSTIRDIPass::finalShading(
    RenderContext* pRenderContext,
    const RenderData& renderData,
    const Texture::SharedPtr& vBuffer,
    const Texture::SharedPtr& depth,
    const Texture::SharedPtr& viewW
)
{
    if (!mpSpatialResampling)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kSpatioResamplingFileName).setShaderModel(kShaderModel).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());
        FALCOR_ASSERT(mpSampleGenerator);
        auto defines = mpScene->getSceneDefines();
        defines.add(mpSampleGenerator->getDefines());
        defines.add(getDefines());
        defines.add(getValidResourceDefines(kOutputChannels, renderData));

        mpSpatialResampling = ComputePass::create(mpDevice, desc, defines, true);
    }
    mpSpatialResampling->getProgram()->addDefines(getValidResourceDefines(kOutputChannels, renderData));
    mpSpatialResampling->getProgram()->addDefines(getDefines());
    auto var = mpSpatialResampling->getRootVar();
    FALCOR_ASSERT(mpIntermediateReservoir);

    var["gIntermediateReservoir"] = mpIntermediateReservoir;
    var["gVBuffer"] = vBuffer;
    var["gDepth"] = depth;
    var["gViewW"] = viewW;
    var["gNormal"] = renderData.getTexture(kInputNormal);

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mFrameDim;
    var["CB"]["isValidViewW"] = viewW == nullptr;

    var["gScene"] = mpScene->getParameterBlock();

    auto bind = [&](const ChannelDesc& channel)
    {
        Texture::SharedPtr pTex = renderData.getTexture(channel.name);
        var[channel.texname] = pTex;
    };
    for (const auto& channel : kOutputChannels)
        bind(channel);

    mpSampleGenerator->setShaderData(var);
    mpScene->setRaytracingShaderData(pRenderContext, var);
    mpSpatialResampling->execute(pRenderContext, {mFrameDim, 1u});
}

void ReSTIRDIPass::endFrame(RenderContext* pRenderContext, const RenderData& renderData)
{
    mpTemporalReservoir.swap(mpIntermediateReservoir);
    mpPrevNormal = renderData.getTexture(kInputNormal);
    mFrameCount++;
}

void ReSTIRDIPass::renderUI(Gui::Widgets& widget) {}
