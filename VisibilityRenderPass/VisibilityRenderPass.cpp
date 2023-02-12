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
#include "VisibilityRenderPass.h"
#include "RenderGraph/RenderPassLibrary.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

const RenderPass::Info VisibilityRenderPass::kInfo { "VisibilityRenderPass", "Insert pass description here." };

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(VisibilityRenderPass::kInfo, VisibilityRenderPass::create);
}

namespace{
    const std::string kLightingShaderFile="RenderPasses/VisibilityRenderPass/Shading.cs.slang";
    const std::string kShadowShaderFile="RenderPasses/VisibilityRenderPass/ReSTIRShadow.cs.slang";
    const std::string kCombineShaderFile="RenderPasses/VisibilityRenderPass/Combine.cs.slang";

    const ChannelList kInputChannels = {
            {"vBuffer","gVBuffer", ""},
            {"motionVecW", "gMVec", "",false,ResourceFormat::RG32Float},
            {"viewW", "gViewW", "", false},
            {"depth", "gDepth", "", true, ResourceFormat::D32Float}
    };
    const std::string kOutputTexName = "gOutColor";
    const std::string kShadingTexName = "gShadingColor";
    const std::string kShadowTexName = "gShadow";
    const ChannelList kOutputChannels = {
            {"color", kOutputTexName,"", false, ResourceFormat::RGBA32Float},
            {"shading", kShadingTexName,"", false, ResourceFormat::RGBA32Float},
            {"shadow", kShadowTexName,"", false, ResourceFormat::R32Float},
    };

    const std::string kCombineShadow = "combineShadow";
    const std::string kRISSamples = "RISSamples";
    const std::string kUseTemporalReuse = "useTemporalReuse";
}

VisibilityRenderPass::VisibilityRenderPass(const Dictionary& dict)  : RenderPass(kInfo) {
    parseDictionary(dict);
    mpSampleGenerator= SampleGenerator::create(SAMPLE_GENERATOR_DEFAULT);
    if(!gpDevice->isFeatureSupported(Device::SupportedFeatures::RaytracingTier1_1)) {
        logError("Inline Raytracing is not supported on this device.");
    }
    Program::DefineList defines;
    {
        Program::Desc desc;
        desc.addShaderLibrary(kShadowShaderFile).csEntry("main").setShaderModel("6_5");
        mpShadowPass = ComputePass::create(desc, defines, true);
    }
    {
        Program::Desc desc;
        desc.addShaderLibrary(kLightingShaderFile).csEntry("main").setShaderModel("6_5");
        mpShadingPass = ComputePass::create(desc, defines, true);
    }
    {
        Program::Desc desc;
        desc.addShaderLibrary(kCombineShaderFile).csEntry("main").setShaderModel("6_5");
        mpCombinePass = ComputePass::create(desc, defines, true);
    }
}

void VisibilityRenderPass::parseDictionary(const Dictionary &dict) {
    for (const auto&[k,v]:dict) {
        if (k == kCombineShadow) {
            mCombineShadow = v;
        }else if(k == kRISSamples) {
            ReSTIRSettings.mRISSamples = v;
        }else if(k == kUseTemporalReuse) {
            ReSTIRSettings.mUseTemporalReuse = v;
        }
    }
}

VisibilityRenderPass::SharedPtr VisibilityRenderPass::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new VisibilityRenderPass(dict));
    return pPass;
}

Dictionary VisibilityRenderPass::getScriptingDictionary()
{
    return Dictionary();
}

RenderPassReflection VisibilityRenderPass::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void VisibilityRenderPass::setScene(RenderContext *pRenderContext, const Scene::SharedPtr &pScene) {
    mFrameCounts = 0;
    mpScene = pScene;
    if(!mpScene) return;
}

void VisibilityRenderPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto &dict = renderData.getDictionary();
    if(mOptionsChanged){
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
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }
    shadowPass(pRenderContext, renderData);
    shadingPass(pRenderContext, renderData);

    pRenderContext->clearTexture(renderData.getTexture("gOutColor").get());
    if(mCombineShadow){
        combinePass(pRenderContext, renderData);
    }
    mFrameCounts++;
}
void VisibilityRenderPass::shadowPass(RenderContext *pRenderContext, const RenderData &renderData) {
    FALCOR_ASSERT(mpShadowPass);
    mpShadowPass->addDefine("RIS_SAMPLES", std::to_string(ReSTIRSettings.mRISSamples));
    mpShadowPass->addDefine("USE_TEMPORAL_REUSE", ReSTIRSettings.mUseTemporalReuse?"1":"0");
    mpShadowPass->getProgram()->addDefines(getValidResourceDefines(kInputChannels, renderData));
    std::vector<ChannelDesc> shadowChannels = {kOutputChannels[2]};
    mpShadowPass->getProgram()->addDefines(getValidResourceDefines(shadowChannels, renderData));
    FALCOR_ASSERT(mpShadowPass->hasVars())

    auto var = mpShadowPass->getRootVar();
    const uint2& frameDim = renderData.getDefaultTextureDims();
    var["PerFrameCB"]["gFrameCount"] = mFrameCounts;
    var["PerFrameCB"]["gFrameDim"] = frameDim;
    mpSampleGenerator->setShaderData(var);
    mpScene->setRaytracingShaderData(pRenderContext, var);

    auto bind = [&](const ChannelDesc &desc){
        if(!desc.texname.empty())var[desc.texname]=renderData.getTexture(desc.name);
    };
    for(const auto &cd:kInputChannels){
        bind(cd);
    }
    for(const auto &cd:shadowChannels){
        bind(cd);
    }
    mpShadowPass->execute(pRenderContext, {frameDim, 1u});
}
void VisibilityRenderPass::shadingPass(RenderContext *pRenderContext, const RenderData &renderData) {
    FALCOR_ASSERT(mpShadingPass);
//    mpShadowPass->addDefine(?)
    mpShadowPass->getProgram()->addDefines(getValidResourceDefines(kInputChannels, renderData));
    std::vector<ChannelDesc> shadingChannels = {kOutputChannels[1]};
    mpShadowPass->getProgram()->addDefines(getValidResourceDefines(shadingChannels, renderData));
    FALCOR_ASSERT(mpShadingPass->hasVars())

    auto var = mpShadingPass->getRootVar();
    const uint2& frameDim = renderData.getDefaultTextureDims();
    var["PerFrameCB"]["gFrameCount"] = mFrameCounts;
    var["PerFrameCB"]["gFrameDim"] = frameDim;

    mpSampleGenerator->setShaderData(var);

    auto bind = [&](const ChannelDesc &desc){
        if(!desc.texname.empty())var[desc.texname]=renderData.getTexture(desc.name);
    };
    for(const auto &cd:kInputChannels){
        bind(cd);
    }
    for(const auto &cd:shadingChannels){
        bind(cd);
    }
    mpShadingPass->execute(pRenderContext, {frameDim, 1u});
}
void VisibilityRenderPass::combinePass(RenderContext *pRenderContext, const RenderData &renderData) {
    FALCOR_ASSERT(mpCombinePass);
    std::vector<ChannelDesc> combineChannels = {kOutputChannels[0]};
    mpShadowPass->getProgram()->addDefines(getValidResourceDefines(combineChannels, renderData));
    FALCOR_ASSERT(mpCombinePass->hasVars())

    auto var = mpCombinePass->getRootVar();
    const uint2& frameDim = renderData.getDefaultTextureDims();
    auto bind = [&](const ChannelDesc &desc){
        if(!desc.texname.empty())var[desc.texname]=renderData.getTexture(desc.name);
    };
    for(const auto &cd:kOutputChannels){
        bind(cd);
    }
    mpCombinePass->execute(pRenderContext, {frameDim, 1u});
}

void VisibilityRenderPass::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;
    dirty |= widget.checkbox("Combine Shadow", mCombineShadow);
    dirty |= widget.var("RISSamples", ReSTIRSettings.mRISSamples, 1u, 64u);
    dirty |= widget.checkbox("Use Temporal Reuse", ReSTIRSettings.mUseTemporalReuse);
    if(dirty){
        mOptionsChanged=true;
    }
}
