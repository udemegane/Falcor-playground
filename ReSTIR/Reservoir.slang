struct RISReservoir
{
    float wSum;
    uint currentSampleId;
    float3 targetPdfSample;
    uint M;
    __init()
    {
        wSum = 0;
        M = 0;
        currentSampleId = 0;
        targetPdfSample = float3(0.f);
    }
    [mutating]
    bool update(const uint xi, const float wi, const float3 pi, const float rand)
    {
        wSum += wi;
        // M += (uint)step(pi, 0.00001);
        bool accept = rand <= wi / wSum;
        if (accept || M == 0)
        {
            currentSampleId = xi;

            targetPdfSample = pi;
        }
        M++;
        return accept;
    }

    float getInvPDF()
    {

        return wSum / (M * length(targetPdfSample));
    }
}

float randSimple(float2 p)
{
    return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

struct CombinedReservoirFactory
{

    RISReservoir master;
    uint M;
    __init()
    {
        master = RISReservoir();
        M = 0;
    }
    // Unbias Update
    [mutating]
    bool update(RISReservoir ri, float3 newPdfSample)
    {
        M += ri.M;
        float fixedW = ri.wSum * length(newPdfSample) / length(ri.targetPdfSample);
        return master.update(ri.currentSampleId, fixedW, newPdfSample, randSimple((ri.targetPdfSample.x, ri.wSum)));
    }
    // Biased Update
    [mutating]
    bool update(RISReservoir ri)
    {
        M += ri.M;
        return master.update(ri.currentSampleId, ri.wSum, ri.targetPdfSample, randSimple((ri.targetPdfSample.x, ri.wSum)));
    }
    [mutating]
    RISReservoir getCombinedReservoir()
    {
        master.M = M;
        return master;
    }
}
