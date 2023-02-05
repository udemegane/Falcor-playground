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
    const char kShaderFile[] = "RenderPasses/ReSTIR/ReSTIR.rt.slang";

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

    const char kMaxBounces[] = "maxBounces";
    const char kComputeDirect[] = "computeDirect";
    const char kUseImportanceSampling[] = "useImportanceSampling";

    const char kRISSampleNums[] = "risSampleNums";
    const char kTemporalReuseMaxM[] = "temporalReuseMaxM";
    const char kUseReSTIR[] = "useReSTIR";
    const char kUseTemporalReuse[] = "useTemporalReuse";
    const char kUseSpatialReuse[] = "useSpatialReuse";
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
        else if (k == kUseTemporalReuse)
        {
            mUseTemporalReuse = v;
        }
        else if (k == kUseSpatialReuse)
        {
            mUseSpatialReuse = v;
        }
    }
}

Dictionary ReSTIR::getScriptingDictionary()
{
    Dictionary dict;
    dict[kTemporalReuseMaxM] = mTemporalReuseMaxM;
    dict[kRISSampleNums] = mRISSampleNums;
    dict[kUseReSTIR] = mUseReSTIR;
    dict[kUseTemporalReuse] = mUseTemporalReuse;
    dict[kUseSpatialReuse] = mUseSpatialReuse;
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
    mRtState.pProgram->addDefine("USE_RESTIR", mUseReSTIR ? "1" : "0");
    mRtState.pProgram->addDefine("RIS_SAMPLE_NUMS", std::to_string(mRISSampleNums));
    mRtState.pProgram->addDefine("TEMPORAL_REUSE_MAX_M", std::to_string(mTemporalReuseMaxM));
    mRtState.pProgram->addDefine("USE_TEMPORAL_REUSE", (mUseTemporalReuse && mFrameCount != 0) ? "1" : "0");
    mRtState.pProgram->addDefine("USE_SPATIAL_REUSE", mUseSpatialReuse ? "1" : "0");

    mRtState.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mRtState.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    if (!mRtState.pVars)
        prepareVars();
    FALCOR_ASSERT(mRtState.pVars);

    auto var = mRtState.pVars->getRootVar();
    var["PerFrameCB"]["gFrameCount"] = mFrameCount;
    var["PerFrameCB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension]
                                                                                   : 0u;
    const uint2 targetDim = renderData.getDefaultTextureDims();
    if (!mpPrevFrameReservoir)
    {
        uint32_t reservoirCount = targetDim.x * targetDim.y;
        mpPrevFrameReservoir = Buffer::createStructured(var["prevFrameReservoir"], reservoirCount,
                                                        ResourceBindFlags::ShaderResource |
                                                            ResourceBindFlags::UnorderedAccess,
                                                        Buffer::CpuAccess::None, nullptr, false);
    }
    var["prevFrameReservoir"] = mpPrevFrameReservoir;
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

    //    const uint2 targetDim = renderData.getDefaultTextureDims();

    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpScene->raytrace(pRenderContext, mRtState.pProgram.get(), mRtState.pVars, uint3(targetDim, 1));
    mFrameCount++;
    pRenderContext->copyResource(mpPrevFrameReservoir.get(), mpPrevFrameReservoir.get());
    // renderData holds the requested resources
    // auto& pTexture = renderData.getTexture("src");
}

void ReSTIR::prepareVars()
{
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mRtState.pProgram);

    mRtState.pProgram->addDefines(mpSampleGenerator->getDefines());
    mRtState.pProgram->setTypeConformances(mpScene->getTypeConformances());

    mRtState.pVars = RtProgramVars::create(mRtState.pProgram, mRtState.pBindingTable);

    auto var = mRtState.pVars->getRootVar();
    mpSampleGenerator->setShaderData(var);
}

void ReSTIR::setScene(RenderContext *pRenderContext, const Scene::SharedPtr &pScene)
{
    mRtState.pProgram = nullptr;
    mRtState.pBindingTable = nullptr;
    mRtState.pVars = nullptr;
    mFrameCount = 0;
    mpScene = pScene;
    if (!mpScene)
        return;

    if (pScene->hasGeometryType(Scene::GeometryType::Custom))
        logWarning("ReSTIR: This render pass does not support custom primitives.");

    RtProgram::Desc desc;
    desc.addShaderModules(mpScene->getShaderModules());
    desc.addShaderLibrary(kShaderFile);
    desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
    desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
    desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

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

void ReSTIR::renderUI(Gui::Widgets &widget)
{
    bool dirty = false;
    dirty |= widget.var("M (Importance Resampling Count)", mRISSampleNums, 1u, 100u);
    dirty |= widget.var("ClampMaxM", mTemporalReuseMaxM, 1u, 100u);
    dirty |= widget.checkbox("Use WRS", mUseReSTIR);
    dirty |= widget.checkbox("Use Temporal Reuse", mUseTemporalReuse);
    dirty |= widget.checkbox("Use Spatial Reuse", mUseSpatialReuse);
    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty)
    {
        mOptionsChanged = true;
    }
}
