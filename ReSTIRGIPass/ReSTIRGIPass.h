/***************************************************************************
 # Copyright (c) 2023, udemegane All rights reserved.
 **************************************************************************/
#pragma once
#include "Falcor.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Rendering/Lights/LightBVHSampler.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EnvMapSampler.h"
#include <random>

using namespace Falcor;

class ReSTIRGIPass : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(ReSTIRGIPass, "ReSTIRGIPass", "Insert pass description here.");

    using SharedPtr = std::shared_ptr<ReSTIRGIPass>;

    /** Create a new render pass object.
        \param[in] pDevice GPU device.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(std::shared_ptr<Device> pDevice, const Dictionary& dict);

    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    ReSTIRGIPass(std::shared_ptr<Device> pDevice, const Dictionary& dict);
    void parseDictionary(const Dictionary& dict);

    Program::DefineList getStaticDefines(const RenderData& renderData);

    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    void initialSampling(
        RenderContext* pRenderContext,
        const RenderData& renderData,
        const Texture::SharedPtr& pVBuffer,
        const Texture::SharedPtr& pDepth,
        const Texture::SharedPtr& pMotionVector
    );

    void temporalResamplingHalfRes(RenderContext* pRenderContext, const RenderData& renderData);

    //    void spatialResamplingHalfRes(RenderContext* pRenderContext, const RenderData& renderData, const Texture::SharedPtr&
    //    pNoiseTexture);

    void finalShading(
        RenderContext* pRenderContext,
        const RenderData& renderData,
        const Texture::SharedPtr& pVBuffer,
        const Texture::SharedPtr& pDepth
    );
    void endFrame();

    Scene::SharedPtr mpScene;

    ComputePass::SharedPtr mpReflectTypes;
    ComputePass::SharedPtr mpInitialSamplingPass;
    ComputePass::SharedPtr mpTemporalResamplingPass;
    ComputePass::SharedPtr mpSpatialResamplingPass;
    ComputePass::SharedPtr mpFinalShadingPass;

    Buffer::SharedPtr mpInitialSamples;
    Buffer::SharedPtr mpTemporalReservoirs;
    Buffer::SharedPtr mpIntermediateReservoirs;
    Buffer::SharedPtr mpSpatialReservoirs;

    //    Texture::SharedPtr mpPrimaryThroughput;

    SampleGenerator::SharedPtr mpSampleGenerator;
    EnvMapSampler::SharedPtr mpEnvMapSampler;
    EmissiveLightSampler::SharedPtr mpEmissiveLightSampler;

    std::mt19937 mEngine;

    bool mVarsChanged = true;
    struct
    {
        //
        float mSecondaryRayLaunchProbability = 0.20f;
        float mRussianRouletteProbability = 0.3f;
        bool mUseImportanceSampling = true;
        uint mMaxBounces = 10;
        bool mUseInfiniteBounces = true;
        bool mExcludeEnvMapEmissiveFromRIS = true;

        bool mUseEnvLight = true;
        bool mUseEmissiveLights = true;
        bool mUseAnalyticsLights = true;
        bool mUseHalfResolutionGI = false;

        // Temporal Resampling Settings
        bool mTemporalResampling = true;
        uint mTemporalReservoirSize = 20;

        // Spatial Resampling Settings
        bool mSpatialResampling = true;
        uint mSpatialNeighborsCount = 4;
        uint mSampleRadius = 100;
        uint mSpatialReservoirSize = 100;
        bool mDoVisibilityTestEachSamples = false;

        // debug
        bool mEvalDirect = true;
        bool mShowVisibilityPointLi = false;
        bool mSplitView = false;
    } mStaticParams;
    ParameterBlock::SharedPtr mpParamsBlock;

    uint2 mFrameDim = uint2(0, 0);
    uint2 mNoiseDim = uint2(0, 0);
    uint mFrameCount = 0;
    bool mOptionsChanged = false;
    bool mGIResolutionChanged = false;
};
