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
#include "HybridRaytracing.h"
#include "RenderGraph/RenderPassLibrary.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

const RenderPass::Info HybridRaytracing::kInfo { "HybridRaytracing", "Insert pass description here." };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(HybridRaytracing::kInfo, HybridRaytracing::create);
}

namespace {
    const std::string kPTracerFile="RenderPasses/HybridRaytracing/HybridPathtrace.cs.slang";

    const ChannelList kInputChannels={
            {"vBuffer","gVBuffer", "", false},
            {"depth", "gDepth", "", false, ResourceFormat::R32Float},
            {"posW", "gPosW", "", false, ResourceFormat::RGBA32Float},
            {"motionVecW", "gMVec", "",true,ResourceFormat::RG32Float},
            {"viewW", "gViewW", "", true, ResourceFormat::RGBA32Float},
    };
    const ChannelList kOutputChannels={
            {"output", "gOutput", "", false, ResourceFormat::RGBA32Float},};

    const std::string kUseHybrid = "useHybrid";
    const std::string kMaxBounces = "maxBounces";
}

HybridRaytracing::HybridRaytracing(const Dictionary &dict): RenderPass(kInfo) {
    parseDictionary(dict);
    mpSampleGenerator=SampleGenerator::create(SAMPLE_GENERATOR_DEFAULT);
    if(!gpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1))
    {
        logError("Inline Raytracing is not supported on this device");
    }
    Program::DefineList defines;
    {
        Program::Desc desc;
        desc.addShaderLibrary(kPTracerFile).csEntry("main").setShaderModel("6_5");
        mpPTracer=ComputePass::create(desc,defines,false);
    }
}

HybridRaytracing::SharedPtr HybridRaytracing::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new HybridRaytracing(dict));
    return pPass;
}

void HybridRaytracing::parseDictionary(const Dictionary& dict)
{
    for (const auto& [key, value] : dict)
    {
        if (key == kUseHybrid)
        {
            mUseHybrid = value;
        }
        else if (key == kMaxBounces)
        {
            mMaxBounces = value;
        }
        else
        {
            logWarning("Unknown field `" + key + "` in a HybridRaytracing dictionary");
        }
    }
}

Dictionary HybridRaytracing::getScriptingDictionary()
{
    Dictionary dict;
    dict[kUseHybrid]=mUseHybrid;
    dict[kMaxBounces]=mMaxBounces;
    return dict;
}

RenderPassReflection HybridRaytracing::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void HybridRaytracing::setScene(RenderContext *pRenderContext, const Scene::SharedPtr &pScene) {
    mpScene=pScene;
    mFrameCount=0;
    Program::DefineList defines;
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kPTracerFile).csEntry("main").setShaderModel("6_5");
        mpPTracer=ComputePass::create(desc,defines,false);
        mpPTracer->getProgram()->addDefines(mpScene->getSceneDefines());
    }
}

void HybridRaytracing::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto &dict = renderData.getDictionary();
    if(mOptionsChanged){
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }
    if (!mpScene)
    {
        for (const auto &cd : kOutputChannels)
        {
            pRenderContext->clearTexture(renderData.getTexture(cd.name).get());
        }
        return;
    }
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }
    pathTrace(pRenderContext,renderData);
}
void HybridRaytracing::pathTrace(RenderContext *pRenderContext, const RenderData &renderData) {
    FALCOR_ASSERT(mpPTracer)
    mpPTracer->addDefine("MAX_BOUNSES", std::to_string(mMaxBounces));
    mpPTracer->addDefine("USE_HYBRID",mUseHybrid?"1":"0");

    mpPTracer->getProgram()->addDefines(mpScene->getSceneDefines());
    mpPTracer->getProgram()->addDefines(mpSampleGenerator->getDefines());
    mpPTracer->getProgram()->addDefines(getValidResourceDefines(kInputChannels,renderData));
    mpPTracer->getProgram()->addDefines(getValidResourceDefines(kOutputChannels,renderData));
    mpPTracer->getProgram()->setTypeConformances(mpScene->getTypeConformances());
    mpPTracer->setVars(ComputeVars::create(mpPTracer->getProgram()->getReflector()));
    FALCOR_ASSERT(mpPTracer->hasVars());

    auto var = mpPTracer->getRootVar();
    const uint2& frameDim = renderData.getDefaultTextureDims();
    var["PerframeCB"]["gFrameCount"]=mFrameCount;
    var["PerframeCB"]["gFrameDim"]=frameDim;
    mpSampleGenerator->setShaderData(var);
    mpScene->setRaytracingShaderData(pRenderContext,var);

    auto bind = [&](const ChannelDesc &desc){
        if(!desc.texname.empty())var[desc.texname]=renderData.getTexture(desc.name);
    };
    for(const auto &cd:kInputChannels){
        bind(cd);
    }
    for(const auto &cd:kOutputChannels){
        bind(cd);
    }

    mpPTracer->execute(pRenderContext, {frameDim, 1u});
}
void HybridRaytracing::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    dirty |=widget.checkbox("Use Hybrid Raytracing", mUseHybrid);
    dirty |=widget.var("Max Bounces", mMaxBounces, 1u, 10u);
    if(dirty){
        mOptionsChanged=true;
    }
}
