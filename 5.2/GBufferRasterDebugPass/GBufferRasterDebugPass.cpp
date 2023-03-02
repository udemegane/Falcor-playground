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
#include "GBufferRasterDebugPass.h"
#include "RenderGraph/RenderPassLibrary.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

const RenderPass::Info GBufferRasterDebugPass::kInfo{"GBufferRasterDebugPass", "Insert pass description here."};

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char *getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary &lib)
{
    lib.registerPass(GBufferRasterDebugPass::kInfo, GBufferRasterDebugPass::create);
}

namespace
{
    const std::string kShaderFile = "RenderPasses/GBufferRasterDebugPass/DebugView.cs.slang";
    const std::string kDepth = "depth";
    const std::string kPosW = "posW";
    const std::string kNormW = "normW";
    const std::string kTangentW = "tangentW";
    const std::string kFaceNormalW = "faceNormalW";
    const std::string kTexCoord = "texCoord";
    const std::string kTexGrad = "texGrad";
    const std::string kMotionVec = "motionVec";
    const std::string kMaterialData = "materialData";
    const std::string kVBuffer = "vBuffer";
    const std::string kDiffuseOpacity = "diffuseOpacity";
    const std::string kSpecRough = "specRough";
    const std::string kEmissive = "emissive";
    const std::string kViewW = "viewW";
    const std::string kPosAndNormWidth = "posAndNormWidth";
    const std::string kLinearZ = "linearZ";
    const std::string kDebugMode = "debugMode";
    const Gui::DropdownList kDebugModeList =
        {
            {(uint8_t)GBufferRasterDebugPass::DebugMode::Depth, "Depth"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::PosW, "PosW"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::NormW, "NormW"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::TangentW, "TangentW"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::FaceNormalW, "FaceNormalW"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::TexCoord, "TexCoord"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::TexGrad, "TexGrad"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::MotionVec, "MotionVec"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::MaterialData, "MaterialData"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::VBuffer, "VBuffer"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::DiffuseOpacity, "DiffuseOpacity"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::SpecRough, "SpecRough"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::Emissive, "Emissive"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::ViewW, "ViewW"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::PosAndNormWidth, "PosAndNormWidth"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::LinearZ, "LinearZ"},
            {(uint8_t)GBufferRasterDebugPass::DebugMode::TileColor, "TileColor"},

    };
    const ChannelList kOutputChannels = {{"output", "gOutColor", "", false, ResourceFormat::RGBA32Float}};
    const ChannelList kInputChannels = {
        {kDepth, "gDepth", "Depth buffer", true, ResourceFormat::D32Float},
        {kPosW, "gPosW", "World space position", true /* optional */, ResourceFormat::RGBA32Float},
        {kNormW, "gNormW", "World space normal", true /* optional */, ResourceFormat::RGBA32Float},
        {kTangentW, "gTangentW", "World space tangent", true /* optional */, ResourceFormat::RGBA32Float},
        {kFaceNormalW, "gFaceNormalW", "Face normal in world space", true /* optional */, ResourceFormat::RGBA32Float},
        {kTexCoord, "gTexC", "Texture coordinate", true /* optional */, ResourceFormat::RG32Float},
        {kTexGrad, "gTexGrads", "Texture gradients (ddx, ddy)", true /* optional */, ResourceFormat::RGBA16Float},
        {kMotionVec, "gMotionVector", "Motion vector", true /* optional */, ResourceFormat::RG32Float},
        {kMaterialData, "gMaterialData", "Material data (ID, header)", true /* optional */, ResourceFormat::RGBA32Uint},
        {kVBuffer, "gVBuffer", "Visibility buffer", true /* optional */, ResourceFormat::Unknown /* set at runtime */},
        {kDiffuseOpacity, "gDiffOpacity", "Diffuse reflection albedo and opacity", true /* optional */, ResourceFormat::RGBA32Float},
        {kSpecRough, "gSpecRough", "Specular reflectance and roughness", true /* optional */, ResourceFormat::RGBA32Float},
        {kEmissive, "gEmissive", "Emissive color", true /* optional */, ResourceFormat::RGBA32Float},
        {kViewW, "gViewW", "View direction in world space", true /* optional */, ResourceFormat::RGBA32Float}, // TODO: Switch to packed 2x16-bit snorm format.
        {kPosAndNormWidth, "gPosNormalFwidth", "Position and normal filter width", true /* optional */, ResourceFormat::RG32Float},
        {kLinearZ, "gLinearZ", "Linear z (and derivative)", true /* optional */, ResourceFormat::RG32Float},
    };
}

GBufferRasterDebugPass::GBufferRasterDebugPass(const Dictionary &dict) : RenderPass(kInfo)
{
    for (const auto &[key, value] : dict)
    {
        if (key == kDebugMode) mDebugMode = (DebugMode)value;
    }
    Program::DefineList defines;
    defines.add("DEBUG_MODE", std::to_string((uint32_t)mDebugMode));
    mpViewPass = ComputePass::create(kShaderFile, "main", defines, true);
}

GBufferRasterDebugPass::SharedPtr GBufferRasterDebugPass::create(RenderContext *pRenderContext, const Dictionary &dict)
{
    SharedPtr pPass = SharedPtr(new GBufferRasterDebugPass(dict));
    return pPass;
}

Dictionary GBufferRasterDebugPass::getScriptingDictionary()
{
    Dictionary dict;
    dict[kDebugMode] = mDebugMode;
    return dict;
}

RenderPassReflection GBufferRasterDebugPass::reflect(const CompileData &compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void GBufferRasterDebugPass::setScene(RenderContext *pRenderContext, const Scene::SharedPtr &pScene)
{
    mpScene = pScene;
}

void GBufferRasterDebugPass::execute(RenderContext *pRenderContext, const RenderData &renderData)
{
    auto &dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }
    if (!mpScene)
        return;
    FALCOR_ASSERT(mpViewPass);
    mpViewPass->addDefine("DEBUG_MODE", std::to_string((uint32_t)(mDebugMode)));
    mpViewPass->getProgram()->addDefines(getValidResourceDefines(kOutputChannels, renderData));
    auto var = mpViewPass->getRootVar();
    const uint2 targetDim = renderData.getDefaultTextureDims();
    var["PerFrameCB"]["frameDim"] = targetDim;

    auto bind = [&](const ChannelDesc &desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto &channel : kInputChannels)
        bind(channel);
    for (auto &channel : kOutputChannels)
        bind(channel);
//    auto div_round_up = [](uint32_t a, uint32_t b)
//    { return (a + b - 1) / b; };
//    const uint2 groupCount = uint2(div_round_up(targetDim.x, 16u), div_round_up(targetDim.y, 16u));
//    uint3 size = mpViewPass->getThreadGroupSize();
    mpViewPass->execute(pRenderContext, {targetDim, 1u});
    // renderData holds the requested resources
    // auto& pTexture = renderData.getTexture("src");
}

void GBufferRasterDebugPass::renderUI(Gui::Widgets &widget)
{
    bool dirty = false;
    dirty |= widget.dropdown("Output", kDebugModeList, (uint32_t &)mDebugMode);
    if (dirty)
    {
        mOptionsChanged = true;
    }
}
