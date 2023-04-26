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
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override;
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    ReSTIRGIPass(std::shared_ptr<Device> pDevice, const Dictionary& dict);
    void parseDictionary(const Dictionary& dict);

    Program::DefineList getStaticDefines();

    void initialSampling(
        RenderContext* pRenderContext,
        const RenderData& renderData,
        const Texture::SharedPtr& pVBuffer,
        const Texture::SharedPtr& pMotionVector,
        const Texture::SharedPtr& pNoiseTexture
    );

    // Move temporal algorithm into initialSampling
//    void temporalResampling(
//        RenderContext* pRenderContext,
//        const RenderData& renderData,
//        const Texture::SharedPtr& pMotionVector,
//        const Texture::SharedPtr& pNoiseTexture
//    );

    // Move spatial algorithm into FinalShading
//    void spatialResampling(RenderContext* pRenderContext, const RenderData& renderData, const Texture::SharedPtr& pNoiseTexture);
    void finalShading(RenderContext* pRenderContext, const RenderData& renderData, const Texture::SharedPtr& pNoiseTexture);
    void endFrame();

    Scene::SharedPtr mpScene;

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

    bool mVarsChanged=true;
    bool mOptionChanged=false;
    struct {
        //
        float mSecondaryRayLaunchProbability=0.20f;
        float mRussianRouletteProbability=0.3f;
        bool mUseImportanceSampling=true;
        uint mMaxBounces=3;
        bool mUseInfiniteBounces=true;

        bool mUseEnvLight=true;
        bool mUseEmissiveLights=true;
        bool mUseAnalyticsLights=true;
        bool mEnableReSTIR=false;

        // Temporal Resampling Settings
        bool mTemporalResampling=true;
        uint mTemporalReservoirSize=20;

        // Spatial Resampling Settings
        bool mSpatialResampling=true;
        uint mSpatialNeighborsCount=10;
        uint mSampleRadius=150;
        uint mSpatialReservoirSize=500;
        bool mDoVisibilityTestEachSamples=false;
//        bool mUnbiased=false;

        // debug
        bool mEvalDirect=true;
        bool mShowVisibilityPointLi=false;
        bool mSplitView=false;
    }mStaticParams;


    uint2 mFrameDim = uint2(0, 0);
    uint2 mNoiseDim = uint2(0, 0);
    uint mFrameCount = 0;
    bool mOptionsChanged = false;
};
