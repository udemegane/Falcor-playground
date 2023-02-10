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
        // pTarget = float3(0.f);
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
