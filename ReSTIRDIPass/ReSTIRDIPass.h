/***************************************************************************
 # Copyright (c) 2023, udemegane All rights reserved.
 **************************************************************************/
#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "Utils/Debug/PixelDebug.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Rendering/Lights/LightBVHSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EnvMapSampler.h"
#include "Rendering/Utils/PixelStats.h"

using namespace Falcor;

class ReSTIRDIPass : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(ReSTIRDIPass, "ReSTIRDIPass", "Insert pass description here.");

    using SharedPtr = std::shared_ptr<ReSTIRDIPass>;

    /** Create a new render pass object.
        \param[in] pDevice GPU device.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(std::shared_ptr<Device> pDevice, const Dictionary& dict);

    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    ReSTIRDIPass(std::shared_ptr<Device> pDevice, const Dictionary& dict);
    void parseDictionary(const Dictionary& dict);
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);
    Program::DefineList getDefines();

    void prepareReservoir(
        RenderContext* pRenderContext,
        const RenderData& renderData,
        const Texture::SharedPtr& vBuffer,
        const Texture::SharedPtr& depth,
        const Texture::SharedPtr& viewW,
        const Texture::SharedPtr& motionVector
    );

    void finalShading(
        RenderContext* pRenderContext,
        const RenderData& renderData,
        const Texture::SharedPtr& vBuffer,
        const Texture::SharedPtr& depth,
        const Texture::SharedPtr& viewW
    );

    void endFrame(RenderContext* pRenderContext, const RenderData& renderData);

    Scene::SharedPtr mpScene;
    SampleGenerator::SharedPtr mpSampleGenerator;
    EnvMapSampler::SharedPtr mpEnvMapSampler;
    EmissiveLightSampler::SharedPtr mpEmissiveSampler;
    PixelStats::SharedPtr mpPixelStats;
    PixelDebug::SharedPtr mpPixelDebug;
    ParameterBlock::SharedPtr mpParamsBlock;

    ComputePass::SharedPtr mpReflectTypes;
    ComputePass::SharedPtr mpTracePass;
    ComputePass::SharedPtr mpSpatialResampling;

    Buffer::SharedPtr mpTemporalReservoir;
    Buffer::SharedPtr mpIntermediateReservoir;

    Texture::SharedPtr mpPrevNormal;

    struct
    {
        uint mRISSampleNums = 8;
        uint mTemporalReuseMaxM = 20;
        bool mAutoSetMaxM = true;
        bool mUseReSTIR = true;
        bool mUseTemporalReuse = true;
        bool mUseSpatialReuse = true;
        uint mSpatialRadius = 5;
        uint mSpatialNeighbors = 4;
    } mStaticParams;

    uint2 mFrameDim = uint2(0, 0);
    uint mFrameCount = 0;
    bool mOptionsChanged = false;
};
