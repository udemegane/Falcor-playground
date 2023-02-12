/***************************************************************************
 # Copyright (c) 2015-22, NVIDIA CORPORATION. All rights reserved.
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
#include "ReSTIR.h"
#include "RenderGraph/RenderPassLibrary.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

const RenderPass::Info ReSTIR::kInfo{"ReSTIR", "Insert pass description here."};

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char *getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary &lib)
{
    lib.registerPass(ReSTIR::kInfo, ReSTIR::create);
}

namespace
{
    const char kTracerFile[] = "RenderPasses/ReSTIR/WRSTracer.rt.slang";
    const char kExecWRSFile[] = "RenderPasses/ReSTIR/WRS.cs.slang";
    const char kFinalShadingFile[] = "RenderPasses/ReSTIR/SpatioTemporalReuse.cs.slang";

    const uint32_t kMaxPayloadSizeBytes = 72u;
    const uint32_t kMaxRecursionDepth = 2u;

    const char kInputViewDir[] = "viewW";

    const ChannelList kInputChannels = {
        {"vBuffer", "gVBuffer", "Visibility buffer"},
        {"motionVecW", "gMVec", "world-space motion vector", true, ResourceFormat::RG32Float},
        {"viewW", "gViewW", "World-Space view Direction", true},
        {"depth", "gDepth", "Depth buffer (NDC)", true, ResourceFormat::R32Float},
    };

    const ChannelList kOutputChannels = {
        {"color", "gOutputColor", "out color by pathtracing", false, ResourceFormat::RGBA32Float}};
    //    const ChannelList kRtOutputChannnels = {
    //
    //    };
    //    const ChannelList  kCsInputChannels ={
    //
    //    };
    const char kMaxBounces[] = "maxBounces";
    const char kComputeDirect[] = "computeDirect";
    const char kUseImportanceSampling[] = "useImportanceSampling";
    const char kRISSampleNums[] = "risSampleNums";
    const char kUseReSTIR[] = "useReSTIR";
    const char kTemporalReuseMaxM[] = "temporalReuseMaxM";
    const char kAutoSetMaxM[] = "autoSetMaxM";
    const char kUseTemporalReuse[] = "useTemporalReuse";
    const char kUseSpatialReuse[] = "useSpatialReuse";
    const char kSpatialRadius[] = "spatialRadius";
    const char kSpatialNeighbors[] = "spatialNeighbors";
    const char kUseFixWeight[] = "useFixWeight";
}

ReSTIR::SharedPtr ReSTIR::create(RenderContext *pRenderContext, const Dictionary &dict)
{
    return SharedPtr(new ReSTIR(dict));
}

ReSTIR::ReSTIR(const Dictionary &dict) : RenderPass(kInfo)
{
    parseDictionary(dict);

    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_DEFAULT);
    FALCOR_ASSERT(mpSampleGenerator);
    if (!gpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
    {
        logError("Raytracing Tire 1.1 is not supported on this device");
    }
}

void ReSTIR::parseDictionary(const Dictionary &dict)
{
    for (const auto &[k, v] : dict)
    {
        if (k == kTemporalReuseMaxM)
        {
            mTemporalReuseMaxM = v;
        }
        else if (k == kRISSampleNums)
        {
            mRISSampleNums = v;
        }
        else if (k == kUseReSTIR)
        {
            mUseReSTIR = v;
        }
        else if (k == kAutoSetMaxM)
        {
            mAutoSetMaxM = v;
        }
        else if (k == kUseTemporalReuse)
        {
            mUseTemporalReuse = v;
        }
        else if (k == kUseSpatialReuse)
        {
            mUseSpatialReuse = v;
        }
        else if (k == kSpatialRadius)
        {
            mSpatialRadius = v;
        }
        else if (k == kSpatialNeighbors)
        {
            mSpatialNeighbors = v;
        }
        else if (k == kUseFixWeight)
        {
            mUseFixWeight = v;
        }
    }
}

Dictionary ReSTIR::getScriptingDictionary()
{
    Dictionary dict;
    dict[kTemporalReuseMaxM] = mTemporalReuseMaxM;
    dict[kRISSampleNums] = mRISSampleNums;
    dict[kAutoSetMaxM] = mAutoSetMaxM;
    dict[kUseReSTIR] = mUseReSTIR;
    dict[kUseTemporalReuse] = mUseTemporalReuse;
    dict[kUseSpatialReuse] = mUseSpatialReuse;
    dict[kSpatialRadius] = mSpatialRadius;
    dict[kSpatialNeighbors] = mSpatialNeighbors;
    dict[kUseFixWeight] = mUseFixWeight;
    return dict;
}

RenderPassReflection ReSTIR::reflect(const CompileData &compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReSTIR::execute(RenderContext *pRenderContext, const RenderData &renderData)
{
    // オプション変数を更新する
    auto &dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    if (!mpScene)
    {
        for (const auto cd : kOutputChannels)
        {
            Texture *pDst = renderData.getTexture(cd.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        return;
    }

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::GeometryChanged))
    {
        throw RuntimeError("MinimalPathTracer: This render pass does not support scene geometry changes.");
    }

    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    const bool useDOF = mpScene->getCamera()->getApertureRadius() > 0.f;
    if (useDOF && renderData[kInputViewDir] == nullptr)
    {
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", kInputViewDir);
    }
    //    execWRS(pRenderContext, renderData);

    traceray(pRenderContext, renderData);
    if (mUseReSTIR)
        spatioTemporalReuse(pRenderContext, renderData);
    mFrameCount++;
}

void ReSTIR::traceray(RenderContext *pRenderContext, const RenderData &renderData)
{
    mRtState.pProgram->addDefine("USE_RESTIR", mUseReSTIR ? "1" : "0");
    mRtState.pProgram->addDefine("RIS_SAMPLE_NUMS", std::to_string(mRISSampleNums));
    mRtState.pProgram->addDefine("TEMPORAL_REUSE_MAX_M", std::to_string(mTemporalReuseMaxM));
    mRtState.pProgram->addDefine("USE_AUTO_SET_MAX_M", mAutoSetMaxM ? "1" : "0");
    mRtState.pProgram->addDefine("USE_TEMPORAL_REUSE", (mUseTemporalReuse && mFrameCount != 0) ? "1" : "0");
    mRtState.pProgram->addDefine("USE_SPATIAL_REUSE", mUseSpatialReuse ? "1" : "0");

    mRtState.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mRtState.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    if (!mRtState.pVars)
        prepareRtVars();
    FALCOR_ASSERT(mRtState.pVars);

    auto var = mRtState.pVars->getRootVar();
    auto &dict = renderData.getDictionary();
    var["PerFrameCB"]["gFrameCount"] = mFrameCount;
    var["PerFrameCB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension]
                                                                                   : 0u;
    auto bind = [&](const ChannelDesc &desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);
    const uint2 targetDim = renderData.getDefaultTextureDims();
    if (!mpIntermediateReservoir)
    {
        uint32_t reservoirCount = targetDim.x * targetDim.y;
        mpIntermediateReservoir = Buffer::createStructured(var["outputReservoir"], reservoirCount,
                                                           ResourceBindFlags::ShaderResource |
                                                               ResourceBindFlags::UnorderedAccess,
                                                           Buffer::CpuAccess::None, nullptr, false);
    }

    var["outputReservoir"] = mpIntermediateReservoir;
    for (auto channel : kOutputChannels)
        bind(channel);

    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpScene->raytrace(pRenderContext, mRtState.pProgram.get(), mRtState.pVars, uint3(targetDim, 1));
}

void ReSTIR::execWRS(RenderContext *pRenderContext, const RenderData &renderData)
{
    mWRSState.pProgram->addDefine("USE_RESTIR", mUseReSTIR ? "1" : "0");
    mWRSState.pProgram->addDefine("RIS_SAMPLES", std::to_string(mRISSampleNums));

    mWRSState.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));

    if (!mWRSState.pVars)
    {
        FALCOR_ASSERT(mpScene);
        FALCOR_ASSERT(mWRSState.pProgram);
        mWRSState.pProgram->addDefines(mpSampleGenerator->getDefines());
        mWRSState.pProgram->addDefines(mpScene->getSceneDefines());
        mWRSState.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mWRSState.pVars = ComputeVars::create(mWRSState.pProgram->getReflector());
        auto var = mWRSState.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
        mpScene->setRaytracingShaderData(pRenderContext, var);
    }
    FALCOR_ASSERT(mWRSState.pVars);
    auto var = mWRSState.pVars->getRootVar();

    const uint2 targetDim = renderData.getDefaultTextureDims();
    if (!mpIntermediateReservoir)
    {
        uint32_t reservoirCount = targetDim.x * targetDim.y;
        mpIntermediateReservoir = Buffer::createStructured(var["outputReservoir"], reservoirCount,
                                                           ResourceBindFlags::ShaderResource |
                                                               ResourceBindFlags::UnorderedAccess,
                                                           Buffer::CpuAccess::None, nullptr, false);
    }
    FALCOR_ASSERT(mpIntermediateReservoir);
    var["outputReservoir"] = mpIntermediateReservoir;
    var["PerFrameCB"]["gFrameCount"] = mFrameCount;
    var["PerFrameCB"]["gScreen"] = targetDim;
    auto bind = [&](const ChannelDesc &desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);

    mWRSState.pState->setProgram(mWRSState.pProgram);
    pRenderContext->dispatch(mWRSState.pState.get(), mWRSState.pVars.get(), uint3(targetDim, 1));
}

void ReSTIR::spatioTemporalReuse(RenderContext *pRenderContext, const RenderData &renderData)
{
    mCsState.pProgram->addDefine("USE_RESTIR", mUseReSTIR ? "1" : "0");
    mCsState.pProgram->addDefine("TEMPORAL_REUSE_MAX_M", std::to_string(mTemporalReuseMaxM));
    mCsState.pProgram->addDefine("USE_AUTO_SET_MAX_M", mAutoSetMaxM ? "1" : "0");
    mCsState.pProgram->addDefine("USE_TEMPORAL_REUSE", (mUseTemporalReuse && mFrameCount != 0) ? "1" : "0");
    mCsState.pProgram->addDefine("USE_SPATIAL_REUSE", mUseSpatialReuse ? "1" : "0");
    mCsState.pProgram->addDefine("SPATIAL_RADIUS", std::to_string(mSpatialRadius));
    mCsState.pProgram->addDefine("SPATIAL_NEIGHBORS", std::to_string(mSpatialNeighbors));
    mCsState.pProgram->addDefine("USE_FIXWEIGHT", mUseFixWeight ? "1" : "0");

    mCsState.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mCsState.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));
    if (!mCsState.pVars)
    {
        FALCOR_ASSERT(mpScene);
        FALCOR_ASSERT(mCsState.pProgram);
        mCsState.pProgram->addDefines(mpSampleGenerator->getDefines());
        mCsState.pProgram->addDefines(mpScene->getSceneDefines());
        mCsState.pProgram->setTypeConformances(mpScene->getTypeConformances());
        mCsState.pVars = ComputeVars::create(mCsState.pProgram->getReflector());
        auto var = mCsState.pVars->getRootVar();
        mpSampleGenerator->setShaderData(var);
        mpScene->setRaytracingShaderData(pRenderContext, var);
    }
    FALCOR_ASSERT(mCsState.pVars);
    auto var = mCsState.pVars->getRootVar();
    const uint2 targetDim = renderData.getDefaultTextureDims();
    if (!mpPrevFrameReservoir)
    {
        uint32_t reservoirCount = targetDim.x * targetDim.y;
        mpPrevFrameReservoir = Buffer::createStructured(var["prevFrameReservoir"], reservoirCount,
                                                        ResourceBindFlags::ShaderResource |
                                                            ResourceBindFlags::UnorderedAccess,
                                                        Buffer::CpuAccess::None, nullptr, false);
    }
    FALCOR_ASSERT(mpIntermediateReservoir);
    var["PerFrameCB"]["gFrameCount"] = mFrameCount;
    var["PerFrameCB"]["gScreen"] = targetDim;
    var["prevFrameReservoir"] = mpPrevFrameReservoir;
    var["intermediateReservoir"] = mpIntermediateReservoir;
    auto bind = [&](const ChannelDesc &desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mCsState.pState->setProgram(mCsState.pProgram);
    auto div_round_up = [](uint32_t a, uint32_t b)
    { return (a + b - 1) / b; };
    const uint2 groupCount = uint2(div_round_up(targetDim.x, 16u), div_round_up(targetDim.y, 16u));
    pRenderContext->dispatch(mCsState.pState.get(), mCsState.pVars.get(), uint3(groupCount, 1u));
}

void ReSTIR::prepareRtVars()
{
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mRtState.pProgram);

    mRtState.pProgram->addDefines(mpSampleGenerator->getDefines());
    mRtState.pProgram->setTypeConformances(mpScene->getTypeConformances());

    mRtState.pVars = RtProgramVars::create(mRtState.pProgram, mRtState.pBindingTable);

    auto var = mRtState.pVars->getRootVar();
    mpSampleGenerator->setShaderData(var);
}

void ReSTIR::prepareCsVars(ComputeProgram::SharedPtr &pProgram, ComputeVars::SharedPtr &pVars)
{
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(pProgram);
    pProgram->addDefines(mpSampleGenerator->getDefines());
    pProgram->addDefines(mpScene->getSceneDefines());
    pProgram->setTypeConformances(mpScene->getTypeConformances());
    pVars = ComputeVars::create(pProgram->getReflector());
    auto var = pVars->getRootVar();
    mpSampleGenerator->setShaderData(var);
}

void ReSTIR::setScene(RenderContext *pRenderContext, const Scene::SharedPtr &pScene)
{
    mFrameCount = 0;
    mpScene = pScene;
    if (!mpScene)
        return;

    if (pScene->hasGeometryType(Scene::GeometryType::Custom))
        logWarning("ReSTIR: This render pass does not support custom primitives.");
    {
        mRtState.pProgram = nullptr;
        mRtState.pBindingTable = nullptr;
        mRtState.pVars = nullptr;
        RtProgram::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kTracerFile);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
        desc.setShaderModel("6_5");

        mRtState.pBindingTable = RtBindingTable::create(2, 1, mpScene->getGeometryCount());
        auto &sbt = mRtState.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        // sbt->setMiss(0, desc.addMiss("scatterMiss"));
        sbt->setMiss(1, desc.addMiss("shadowMiss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
                             desc.addHitGroup("", "shadowTriangleMeshAnyHit"));
        }

        mRtState.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
    }

    mCsState.pProgram = ComputeProgram::createFromFile(kFinalShadingFile, "main", Program::DefineList(),
                                                       Shader::CompilerFlags::None, "6_5");
    mCsState.pState = ComputeState::create();

    mWRSState.pProgram = ComputeProgram::createFromFile(kExecWRSFile, "main", Program::DefineList(),
                                                        Shader::CompilerFlags::None, "6_5");
    mWRSState.pState = ComputeState::create();
}

void ReSTIR::renderUI(Gui::Widgets &widget)
{
    bool dirty = false;
    dirty |= widget.var("M (Importance Resampling Count)", mRISSampleNums, 1u, 100u);
    dirty |= widget.var("ClampMaxM", mTemporalReuseMaxM, 1u, 100u);
    dirty |= widget.checkbox("Auto Set Max M", mAutoSetMaxM);
    dirty |= widget.checkbox("Use WRS", mUseReSTIR);
    dirty |= widget.checkbox("Fix Weight", mUseFixWeight);
    dirty |= widget.checkbox("Use Temporal Reuse", mUseTemporalReuse);
    dirty |= widget.checkbox("Use Spatial Reuse", mUseSpatialReuse);
    dirty |= widget.var("Spatial Radius", mSpatialRadius, 1u, 30u);
    dirty |= widget.var("Spatial Neighbors", mSpatialNeighbors, 1u, 30u);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
    }
}
