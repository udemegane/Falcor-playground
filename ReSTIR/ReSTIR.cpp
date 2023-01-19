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

const RenderPass::Info ReSTIR::kInfo{"ReSTIR", "Non-Official Simple ReSTIR implementation"};

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char *getProjDir() {
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary &lib) {
    lib.registerPass(ReSTIR::kInfo, ReSTIR::create);
}

namespace {
    const uint32_t kMaxPayloadSizeBytes = 72u;
    const uint32_t kMaxRecursionDepth = 2u;
    const char kShaderFile[] = "RenderPasses/ReSTIR/ReSTIR.rt.slang";
    const char kInputViewDir[] = "viewW";
    const ChannelList kInputChannels = {
            {"vBuffer",    "gVBuffer", ""},
            {"motionVecW", "gMVec",    "world-space motion vector"},
            {"viewW",      "gViewW",   "world-space view vector", true},
    };
    const ChannelList kOutputChannels = {
            {"color", "gOutColor", "", false, ResourceFormat::RGBA32Float}
    };

    const char kRISSampleNums[] = "risSampleNums";
    const char kUseReSTIR[] = "useReSTIR";
    const char kUseTemporalReuse[] = "useTemporalReuse";
    const char kUseSpatialReuse[] = "useSpatialReuse";
}

ReSTIR::SharedPtr ReSTIR::create(RenderContext *pRenderContext, const Dictionary &dict) {
    SharedPtr pPass = SharedPtr(new ReSTIR(dict));
    return pPass;
}

void ReSTIR::parseDictionary(const Dictionary &dict) {
    for (const auto &[k, v]: dict) {
        if (k == kRISSampleNums) {
            mRISSampleNums = v;
        } else if (k == kUseReSTIR) {
            mUseReSTIR = v;
        } else if (k == kUseTemporalReuse) {
            mUseTemporalReuse = v;
        } else if (k == kUseSpatialReuse) {
            mUseSpatialReuse = v;
        }
    }
}

ReSTIR::ReSTIR(const Dictionary &dict) : RenderPass(kInfo) {
    parseDictionary(dict);

    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_UNIFORM);
    FALCOR_ASSERT(mpSampleGenerator);
}

Dictionary ReSTIR::getScriptingDictionary() {
    Dictionary dict;
    dict[kRISSampleNums] = mRISSampleNums;
    dict[kUseReSTIR] = mUseReSTIR;
    dict[kUseTemporalReuse] = mUseTemporalReuse;
    dict[kUseSpatialReuse] = mUseSpatialReuse;
    return dict;
}

RenderPassReflection ReSTIR::reflect(const CompileData &compileData) {
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ReSTIR::execute(RenderContext *pRenderContext, const RenderData &renderData) {
    // renderData holds the requested resources
    // auto& pTexture = renderData.getTexture("src");
    auto &dict = renderData.getDictionary();
    if (mOptionsChanged) {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }
    if (!mpScene) {
        for (const auto &cd: kOutputChannels) {
            Texture *pDst = renderData.getTexture(cd.name).get();
            if (pDst) {
                pRenderContext->clearTexture(pDst, float4(0, 0, 0, 0));
            }
        }
        return;
    }

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::GeometryChanged)) {
        throw RuntimeError("This ReSTIR does not support geometry change");
    }

    if (mpScene->getRenderSettings().useEmissiveLights) {
        mpScene->getLightCollection(pRenderContext);
    }

    const bool useDOF = mpScene->getCamera()->getApertureRadius() > 0.f;
    if (useDOF && renderData[kInputViewDir] == nullptr) {
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", kInputViewDir);
    }

    mRtState.pProgram->addDefine("RIS_SAMPLE_NUMS", std::to_string(mRISSampleNums));
    mRtState.pProgram->addDefine("USE_RESTIR", mUseReSTIR ? "1" : "0");
//    mRtState.pProgram->addDefine("USE_TEMPORAL_REUSE", mUseTemporalReuse ? "1" : "0");
//    mRtState.pProgram->addDefine("USE_SPATIAL_REUSE", mUseSpatialReuse ? "1" : "0");

    mRtState.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mRtState.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    if (!mRtState.pVars)prepareVars();
    FALCOR_ASSERT(mRtState.pVars);

    auto var = mRtState.pVars->getRootVar();
    var["PerFrameCB"]["gFrameCount"] = mFrameCount;
    var["PerFrameCB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension]
                                                                                   : 0u;

    for (const auto &channel: kInputChannels)
        if (!channel.texname.empty())
            var[channel.texname] = renderData.getTexture(channel.name);
    for (const auto &channel: kOutputChannels)
        if (!channel.texname.empty())
            var[channel.texname] = renderData.getTexture(channel.name);

    const uint2 &targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpScene->raytrace(pRenderContext, mRtState.pProgram.get(), mRtState.pVars, uint3(targetDim, 1));
    mFrameCount++;
}

void ReSTIR::prepareVars() {
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mRtState.pProgram);

    mRtState.pProgram->addDefines(mpSampleGenerator->getDefines());
    mRtState.pProgram->setTypeConformances(mpScene->getTypeConformances());
    mRtState.pVars = RtProgramVars::create(mRtState.pProgram, mRtState.pBindingTable);

    auto var = mRtState.pVars->getRootVar();
    mpSampleGenerator->setShaderData(var);
}

void ReSTIR::setScene(RenderContext *pRenderContext, const Scene::SharedPtr &pScene) {
    mpScene = pScene;
    mRtState.pProgram = nullptr;
    mRtState.pVars = nullptr;
    mRtState.pBindingTable = nullptr;
    mFrameCount = 0;
    if (!mpScene)return;
    if (mpScene->hasGeometryType(Scene::GeometryType::Custom))
        logWarning("ReSTIR: This render pass does not support custom primitives.");

    RtProgram::Desc desc;
    desc.addShaderModules(mpScene->getShaderModules());
    desc.addShaderLibrary(kShaderFile);
    desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
    desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
    desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);
    mRtState.pBindingTable = RtBindingTable::create(1, 1, mpScene->getGeometryCount());

    mRtState.pBindingTable->setRayGen(desc.addRayGen("rayGen"));
    mRtState.pBindingTable->setMiss(0, desc.addMiss("shadowMiss"));

    if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh)) {
        mRtState.pBindingTable->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
                                            desc.addHitGroup("", "shadowTriangleMeshAnyHit"));
    }

    mRtState.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());
}

void ReSTIR::renderUI(Gui::Widgets &widget) {
    bool dirty = false;
    dirty |= widget.checkbox("Use ReSTIR", mUseReSTIR);
    dirty |= widget.checkbox("Use Temporal Reuse", mUseTemporalReuse);
    dirty |= widget.checkbox("Use Spatial Reuse", mUseSpatialReuse);

    if (dirty) {
        mOptionsChanged = true;
    }
}
