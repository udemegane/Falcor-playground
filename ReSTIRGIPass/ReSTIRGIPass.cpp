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
#include "ReSTIRGIPass.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

using namespace Falcor;

namespace
{
const std::string kInitialSamplingFile = "RenderPasses/ReSTIRGIPass/InitialSampling.cs.slang";
const std::string kTemporalSamplingFIle = "RenderPasses/ReSTIRGIPass/TemporalResampling.cs.slang";
const std::string kSpatialSamplingFile = "RenderPasses/ReSTIRGIPass/SpatialResampling.cs.slang";
const std::string kFinalShadingFile = "RenderPasses/ReSTIRGIPass/FinalShading.cs.slang";
const std::string kShaderModel = "6_5";

const std::string kInputVBuffer = "vBuffer";
const std::string kInputMotionVector = "motionVector";
const std::string kInputDepth = "depth";
const std::string kInputNormal = "normal";
const std::string kInputNoise = "noiseTex";

const Falcor::ChannelList kInputChannels = {
    {kInputVBuffer, "gVBuffer", "Visibility Buffer"},
    {kInputMotionVector, "gMotionVector", "Motion Vector"},
    {kInputDepth, "gDepth", "Depth"},
    {kInputNormal, "gNormal", "Surface Normal"},
    {kInputNoise, "gNoiseTex", "Noise Texture"},
};

const Falcor::ChannelList kOutputChannels = {
    {"color", "gColor", "Color", true, ResourceFormat::RGBA32Float},
    {"diffuseRadiance", "gDiffuseRadiance", "", true, ResourceFormat::RGBA32Float},
    {"specularRadiance", "gSpecularRadiance", "", true, ResourceFormat::RGBA32Float},
};

} // namespace

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, ReSTIRGIPass>();
}

ReSTIRGIPass::ReSTIRGIPass(std::shared_ptr<Device> pDevice, const Dictionary& dict) : RenderPass(std::move(pDevice))
{
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
    // TODO: create dictionary members for options
    return d;
}

void ReSTIRGIPass::parseDictionary(const Dictionary& dict)
{
    for (const auto& [k, v] : dict)
    {
        // TODO: assign options
    }
}

void ReSTIRGIPass::compile(RenderContext* pRenderContext, const CompileData& compileData)
{
    mFrameDim = compileData.defaultTexDims;
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

    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    const auto& pVBuffer = renderData.getTexture(kInputVBuffer);
    const auto& pNormal = renderData.getTexture(kInputNormal);
    const auto& pMVec = renderData.getTexture(kInputMotionVector);
    const auto& pNoise = renderData.getTexture(kInputNoise);
    FALCOR_ASSERT(pNoise);
    mNoiseDim = {pNoise.get()->getHeight(), pNoise.get()->getWidth()};

    initialSampling(pRenderContext, renderData, pVBuffer, pNormal,pMVec,pNoise);
//    temporalResampling(pRenderContext, renderData, pMVec, pNoise);
    spatialResampling(pRenderContext, renderData, pNoise);
    finalShading(pRenderContext, renderData, pNoise);
    endFrame();
    // renderData holds the requested resources
    // auto& pTexture = renderData.getTexture("src");
}

void ReSTIRGIPass::initialSampling(
    RenderContext* pRenderContext,
    const RenderData& renderData,
    const Texture::SharedPtr& pVBuffer,
    const Texture::SharedPtr& pNormal,
    const Texture::SharedPtr& pMotionVector,
    const Texture::SharedPtr& pNoiseTexture
)
{
    FALCOR_ASSERT(pVBuffer);
    FALCOR_ASSERT(pNormal);

    if (!mpInitialSamplingPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kInitialSamplingFile).setShaderModel(kShaderModel).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        auto defines = mpScene->getSceneDefines();
        FALCOR_ASSERT(mpSampleGenerator);
        defines.add(mpSampleGenerator->getDefines());

        mpInitialSamplingPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpInitialSamplingPass);

    auto var = mpInitialSamplingPass->getRootVar();

    if (!mpInitialSamples)
    {
        uint32_t frameDim1D = mFrameDim.x * mFrameDim.y;
        mpInitialSamples = Buffer::createStructured(
            mpDevice.get(), var["gInitSamples"], frameDim1D, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
    }
    if (!mpPrimaryThroughput)
    {
        mpPrimaryThroughput = Texture::create2D(
            mpDevice.get(), (uint32_t)mFrameDim.x, (uint32_t)mFrameDim.y, ResourceFormat::RGBA32Float, 1, 1, nullptr,
            ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess
        );
    }

    if (!mpTemporalReservoirs)
    {
        uint32_t reservoirCounts = mFrameDim.x * mFrameDim.y;
        mpTemporalReservoirs = Buffer::createStructured(
            mpDevice.get(), var["gTemporalReservoirs"], reservoirCounts, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
    }

    var["gInitSamples"] = mpInitialSamples;
    var["gThroughput"] = mpPrimaryThroughput;
    var["gTemporalReservoirs"] = mpTemporalReservoirs;

    var["gVBuffer"] = pVBuffer;
    var["gNormal"] = pNormal;
    var["gNoise"] = pNoiseTexture;
    var["gMotionVector"] = pMotionVector;


    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mFrameDim;
    var["CB"]["gNoiseTexDim"] = mNoiseDim;

    mpSampleGenerator->setShaderData(var);
    mpScene->setRaytracingShaderData(pRenderContext, var);
    mpInitialSamplingPass->execute(pRenderContext, {mFrameDim, 1u});
}

//void ReSTIRGIPass::temporalResampling(
//    RenderContext* pRenderContext,
//    const RenderData& renderData,
//    const Texture::SharedPtr& pMotionVector,
//    const Texture::SharedPtr& pNoiseTexture
//)
//{
//    FALCOR_ASSERT(pMotionVector);
//    if (!mpTemporalResamplingPass)
//    {
//        Program::Desc desc;
//        desc.addShaderModules(mpScene->getShaderModules());
//        desc.addShaderLibrary(kTemporalSamplingFIle).setShaderModel(kShaderModel).csEntry("main");
//        desc.addTypeConformances(mpScene->getTypeConformances());
//
//        auto defines = mpScene->getSceneDefines();
//        defines.add(mpSampleGenerator->getDefines());
//        mpTemporalResamplingPass = ComputePass::create(mpDevice, desc, defines, true);
//    }
//    FALCOR_ASSERT(mpTemporalResamplingPass);
//    auto var = mpTemporalResamplingPass->getRootVar();
//
//    if (!mpTemporalReservoirs)
//    {
//        uint32_t reservoirCounts = mFrameDim.x * mFrameDim.y;
//        mpTemporalReservoirs = Buffer::createStructured(
//            mpDevice.get(), var["gTemporalReservoirs"], reservoirCounts, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess,
//            Buffer::CpuAccess::None, nullptr, false
//        );
//    }
//    FALCOR_ASSERT(mpInitialSamples);
//    var["initSamples"] = mpInitialSamples;
//    var["gTemporalReservoirs"] = mpTemporalReservoirs;
//    var["gMotionVector"] = pMotionVector;
//    var["gNoise"] = pNoiseTexture;
//
//    var["CB"]["gFrameCount"] = mFrameCount;
//    var["CB"]["gFrameDim"] = mFrameDim;
//    var["CB"]["gNoiseTexDim"] = mNoiseDim;
//
//
//    var["gScene"] = mpScene->getParameterBlock();
//    mpSampleGenerator->setShaderData(var);
//    mpTemporalResamplingPass->execute(pRenderContext, {mFrameDim, 1u});
//}

void ReSTIRGIPass::spatialResampling(RenderContext* pRenderContext, const RenderData& renderData, const Texture::SharedPtr& pNoiseTexture)
{
    //    FALCOR_ASSERT();
    if (!mpSpatialResamplingPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kSpatialSamplingFile).setShaderModel(kShaderModel).csEntry("main");
        desc.addTypeConformances(mpScene->getTypeConformances());

        auto defines = mpScene->getSceneDefines();
        mpSpatialResamplingPass = ComputePass::create(mpDevice, desc, defines, true);
    }
    FALCOR_ASSERT(mpSpatialResamplingPass);
    auto var = mpSpatialResamplingPass->getRootVar();
    FALCOR_ASSERT(mpTemporalReservoirs);
    if(!mpSpatialReservoirs){
        uint32_t reservoirCounts=mFrameDim.x*mFrameDim.y;
        mpSpatialReservoirs = Buffer::createStructured(
            mpDevice.get(), var["gSpatialReservoirs"], reservoirCounts, ResourceBindFlags::ShaderResource| ResourceBindFlags::UnorderedAccess,
            Buffer::CpuAccess::None, nullptr, false
        );
    }
    var["gSpatialReservoirs"] = mpSpatialReservoirs;
    var["gTemporalReservoirs"] = mpTemporalReservoirs;

    var["gNoise"] = pNoiseTexture;

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mFrameDim;
    var["CB"]["gNoiseTexDim"] = mNoiseDim;

    var["gScene"] = mpScene->getParameterBlock();

    mpSampleGenerator->setShaderData(var);
    mpSpatialResamplingPass->execute(pRenderContext, {mFrameDim, 1u});
}

void ReSTIRGIPass::finalShading(RenderContext* pRenderContext, const RenderData& renderData, const Texture::SharedPtr& pNoiseTexture)
{
    if (!mpFinalShadingPass)
    {
        Program::Desc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kFinalShadingFile).setShaderModel(kShaderModel).csEntry("main");
        auto defines = mpScene->getSceneDefines();
        // defines.add()
        defines.add(getValidResourceDefines(kOutputChannels, renderData));
        mpFinalShadingPass = ComputePass::create(mpDevice, desc, defines, true);
    }

    mpFinalShadingPass->getProgram()->addDefines(getValidResourceDefines(kOutputChannels, renderData));
    auto var = mpFinalShadingPass->getRootVar();
    FALCOR_ASSERT(mpTemporalReservoirs);
    FALCOR_ASSERT(mpPrimaryThroughput);

    var["gInitSamples"] = mpInitialSamples;
    var["gTemporalReservoirs"] = mpTemporalReservoirs;
    var["gThroughput"] = mpPrimaryThroughput;
    var["gNoise"] = pNoiseTexture;

    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gFrameDim"] = mFrameDim;
    var["CB"]["gNoiseTexDim"] = mNoiseDim;

    var["gScene"] = mpScene->getParameterBlock();

    auto bind = [&](const ChannelDesc& channel)
    {
        Texture::SharedPtr pTex = renderData.getTexture(channel.name);
        var[channel.texname] = pTex;
    };
    for (const auto& channel : kOutputChannels)
        bind(channel);
    mpFinalShadingPass->execute(pRenderContext, {mFrameDim, 1u});
}

void ReSTIRGIPass::endFrame()
{
    mFrameCount++;
}

void ReSTIRGIPass::renderUI(Gui::Widgets& widget) {}
