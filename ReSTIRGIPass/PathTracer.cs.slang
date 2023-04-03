#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"


import Utils.Geometry.GeometryHelpers;
import Utils.Debug.PixelDebug;

import Scene.Shading;
import Scene.Material.ShadingUtils;

import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.LightHelpers;

import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;

static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;


enum class LightType{
    EnvMap,
    Emissive,
    Analytic
};

struct LightSample{
    float3 Li;
    float pdf;
    float3 origin;
    float distance;
    float3 dir;
    uint lightType;
}
// class CustomSampler{
//     SampleGenerator sg;
//     Texture2D<float4> noiseTex;
//     bool useTexture;
//     void register<T>(T resource){
// s
//     }
//     __init(const bool useTexture, inout SampleGenerator sg, inout Texture2D<float4> noise){
//         this.sg = sg;
//         this.useTexture = useTexture;
//         if(useTexture){
//             noiseTex=noise;
//         }
//     }

//     float next1D(){
//         if(useTexture)
//             return sampleNext1D(sg);
//     }
// }

bool selectLightType(out uint lightType, out float pdf , float rand){
    float p[3];

    p[0]=kUseEnvLight?1.f:0.f;
    p[1]=kUseEmissiveLights?1.f:0.f;
    p[2]=kUseAnalyticLights?1.f:0.f;

    float sum = p[0]+p[1]+p[2];
    if(sum!=0.f){
        float invSum=1.f/sum;
        p[0]*=invSum;
        p[1]*=invSum;
        p[2]*=invSum;
    }

    [unroll]
    for(lightType=0; lightType<3; ++lightType){
        if(rand < p[lightType]){
             pdf=p[lightType];
            return true;
        }
        rand-=p[lightType];
    }
    return false;
}

bool generateAnalyticLightsSample(const ShadingData sd, inout LightSample ls , inout SampleGenerator sg){

}

bool generateEmissiveLightsSample(const ShadingData sd, inout LightSample ls , inout SampleGenerator sg){

}

bool generateEnvLightSample(const ShadingData sd, inout LightSample ls , inout SampleGenerator sg){

}

bool generateLightSample(const ShadingData sd, inout LightSample ls, inout SampleGenerator sg){
    LightSample ls = {};
    uint lightType;
    float selectionPdf;
    if(!selectLightType(lightType, selectionPdf, sampleNext1D(sg)))return false;

    bool valid=false;

    if(!valid) return false;

    if(kUseEnvLight && lightType==(uint)LightType::EnvMap)
    ls.lightType = lightType;
    ls.pdf *= selectionPdf;
    ls.Li /= selectionPdf;

    return true;
}

[numthreads(16,16,1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID){

}
