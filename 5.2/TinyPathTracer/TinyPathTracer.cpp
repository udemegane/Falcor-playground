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
#include "TinyPathTracer.h"
#include "RenderGraph/RenderPassLibrary.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

const RenderPass::Info TinyPathTracer::kInfo{"TinyPathTracer", "Insert pass description here."};

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char *getProjDir() {
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary &lib) {
    lib.registerPass(TinyPathTracer::kInfo, TinyPathTracer::create);
}

namespace {
    const char kShaderFile[] = "RenderPasses/TinyPathTracer/TinyPathTracer.rt.slang";

    // traversal stack sizeってなんですか？
    const uint32_t kMaxPayloadSizeBytes = 72u;
    const uint32_t kMaxRecursionDepth = 2u;

    // viewWってなんですか？
    // worldspace view directionってなんですか？
    const char kInputViewDir[] = "viewW";

    const ChannelList kInputChannels = {
            {"vbuffer", "gVBuffer", "Visibility buffer"},
            {"viewW", "gViewW", "World-Space view Direction", true},
    };

    const ChannelList kOutputChannels = {
            {"color", "gOutputColor", "out color by pathtracing", false, ResourceFormat::RGBA32Float}
    };

    const char kMaxBounces[] = "maxBounces";
    const char kComputeDirect[] = "computeDirect";
    // const char kDirectOnly[] = "directOnly";
    const char kUseImportanceSampling[] = "useImportanceSampling";
}

TinyPathTracer::SharedPtr TinyPathTracer::create(RenderContext *pRenderContext, const Dictionary &dict) {
    return SharedPtr(new TinyPathTracer(dict));
}

TinyPathTracer::TinyPathTracer(const Dictionary &dict) : RenderPass(kInfo) {
    parseDictionary(dict);

    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_DEFAULT);
    FALCOR_ASSERT(mpSampleGenerator);
}

// これはなんですか？
// 名前のまんまでした
void TinyPathTracer::parseDictionary(const Dictionary &dict) {
    for (const auto&[key, value]: dict) {
        if (key == kMaxBounces)mMaxBounces = value;
        else if (key == kComputeDirect)mComputeDirect = value;
        // else if (key == kDirectOnly)mDirectOnly = value;
        else if (key == kUseImportanceSampling)mUseImportanceSampling = value;
        else logWarning("Unknown field '{}' in TinyPathTracer dictionary.", key);
    }
}

Dictionary TinyPathTracer::getScriptingDictionary() {
    Dictionary d;
    d[kMaxBounces] = mMaxBounces;
    d[kComputeDirect] = mComputeDirect;
    // d[kDirectOnly] = mDirectOnly;
    d[kUseImportanceSampling] = mUseImportanceSampling;
    return d;
}

RenderPassReflection TinyPathTracer::reflect(const CompileData &compileData) {
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void TinyPathTracer::execute(RenderContext *pRenderContext, const RenderData &renderData) {
    // オプション変数を更新する
    auto &dict = renderData.getDictionary();
    if (mOptionsChanged) {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }

    if (!mpScene) {
        for (const auto cd: kOutputChannels) {
            Texture *pDst = renderData.getTexture(cd.name).get();
            if (pDst)pRenderContext->clearTexture(pDst);
        }
        return;
    }

    if (is_set(mpScene->getUpdates(), Scene::UpdateFlags::GeometryChanged))
    {
        throw RuntimeError("MinimalPathTracer: This render pass does not support scene geometry changes.");
    }

    // シーンの変更を許可しないのはなぜですか？

    if (mpScene->getRenderSettings().useEmissiveLights) {
        mpScene->getLightCollection(pRenderContext);
    }

    const bool useDOF = mpScene->getCamera()->getApertureRadius() > 0.f;
    if (useDOF && renderData[kInputViewDir] == nullptr) {
        // これはなんですか？
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", kInputViewDir);
    }

    // シェーダーに定数を追加していきますよ。
    mTracer.pProgram->addDefine("MAX_BOUNCES", std::to_string(mMaxBounces));
    mTracer.pProgram->addDefine("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    // mTracer.pProgram->addDefine("DIRECT_ONLY", mDirectOnly ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");

    mTracer.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracer.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    if (!mTracer.pVars) prepareVars();
    FALCOR_ASSERT(mTracer.pVars);

    auto var = mTracer.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;

    auto bind = [&](const ChannelDesc &desc) {
        if (!desc.texname.empty()) {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel: kInputChannels) bind(channel);
    for (auto channel: kOutputChannels) bind(channel);

    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(targetDim, 1));
    mFrameCount++;
    // renderData holds the requested resources
    // auto& pTexture = renderData.getTexture("src");
}

void TinyPathTracer::prepareVars() {
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mTracer.pProgram);

    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    mTracer.pVars = RtProgramVars::create(mTracer.pProgram, mTracer.pBindingTable);

    auto var = mTracer.pVars->getRootVar();
    mpSampleGenerator->setShaderData(var);
}

void TinyPathTracer::setScene(RenderContext *pRenderContext, const Scene::SharedPtr &pScene) {
    mTracer.pProgram = nullptr;
    mTracer.pBindingTable = nullptr;
    mTracer.pVars= nullptr;
    mFrameCount = 0;
    mpScene = pScene;
    if (!mpScene) return;

    if (pScene->hasGeometryType(Scene::GeometryType::Custom))
        logWarning("TinyPathTracer: This render pass does not support custom primitives.");

    RtProgram::Desc desc;
    desc.addShaderModules(mpScene->getShaderModules());
    desc.addShaderLibrary(kShaderFile);
    desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
    desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
    desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

    mTracer.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
    auto &sbt = mTracer.pBindingTable;
    sbt->setRayGen(desc.addRayGen("rayGen"));
    sbt->setMiss(0, desc.addMiss("scatterMiss"));
    sbt->setMiss(1, desc.addMiss("shadowMiss"));

    if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh)) {
        sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
                         desc.addHitGroup("scatterTriangleMeshClosestHit", "scatterTriangleMeshAnyHit"));
        sbt->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
                         desc.addHitGroup("", "shadowTriangleMeshAnyHit"));
    }

    if (mpScene->hasGeometryType(Scene::GeometryType::DisplacedTriangleMesh)) {
        sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::DisplacedTriangleMesh),
                         desc.addHitGroup("scatterDisplacedTriangleMeshClosestHit", "",
                                          "displacedTriangleMeshIntersection"));
        sbt->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::DisplacedTriangleMesh),
                         desc.addHitGroup("", "", "displacedTriangleMeshIntersection"));
    }

    if (mpScene->hasGeometryType(Scene::GeometryType::Curve)) {
        sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::Curve),
                         desc.addHitGroup("scatterCurveClosestHit", "", "curveIntersection"));
        sbt->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::Curve),
                         desc.addHitGroup("", "", "curveIntersection"));
    }

    if (mpScene->hasGeometryType(Scene::GeometryType::SDFGrid)) {
        sbt->setHitGroup(0, mpScene->getGeometryIDs(Scene::GeometryType::SDFGrid),
                         desc.addHitGroup("scatterSdfGridClosestHit", "", "sdfGridIntersection"));
        sbt->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::SDFGrid),
                         desc.addHitGroup("", "", "sdfGridIntersection"));
    }
    mTracer.pProgram = RtProgram::create(desc, mpScene->getSceneDefines());

}


void TinyPathTracer::renderUI(Gui::Widgets &widget) {
    bool dirty = false;

    dirty |= widget.var("Max bounces", mMaxBounces, 0u, 1u << 16);
    widget.tooltip("Maximum path length for indirect illumination.\n0 = direct only\n1 = one indirect bounce etc.",
                   true);

    dirty |= widget.checkbox("Evaluate direct illumination", mComputeDirect);
    widget.tooltip("Compute direct illumination.\nIf disabled only indirect is computed (when max bounces > 0).", true);

    dirty |= widget.checkbox("Use importance sampling", mUseImportanceSampling);
    widget.tooltip("Use importance sampling for materials", true);

    // If rendering options that modify the output have changed, set flag to indicate that.
    // In execute() we will pass the flag to other passes for reset of temporal data etc.
    if (dirty) {
        mOptionsChanged = true;
    }
}
