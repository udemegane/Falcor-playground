import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;

struct Params
{
    EmissiveLightSampler emissiveSampler;
    EnvMapSampler envMapSampler;

    bool test() { emissiveSampler.evalTriangleSelectionPdf(float3(0.f), float3(1.0f, 0.0f, 0.0f), true, 0u); }
}
