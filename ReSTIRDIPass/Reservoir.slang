import Utils.Math.PackedFormats;
struct Sample
{
    uint currentSampleId;
    uint8_t type;
}

struct PackedReservoir
{
    // 49B
    uint4 targetPdfSampleWSum;
    uint2 IdAndM;
    uint8_t type;
}
struct Reservoir
{
    float wSum;
    Sample s;
    float3 targetPdfSample;
    uint M;
    __init()
    {
        wSum = 0;
        M = 0;
        s = {};
        targetPdfSample = float3(0.f);
    }
    [mutating]
    bool update(const Sample s, const float wi, const float3 pi, const float rand)
    {
        wSum += wi;
        bool accept = rand <= wi / wSum;
        if (accept || M == 0)
        {
            this.s = s;

            targetPdfSample = pi;
        }
        M++;
        return accept;
    }

    float getInvPDF() { return wSum / (M * length(targetPdfSample)); }

    PackedReservoir pack()
    {
        PackedReservoir p;
        p.IdAndM.x = this.s.currentSampleId;
        p.IdAndM.y = this.M;
        p.targetPdfSampleWSum.xyz = asuint(targetPdfSample);
        p.targetPdfSampleWSum.w = asuint(wSum);
        p.type = s.type;
        return p;
    }

    static Reservoir unpack(PackedReservoir p)
    {
        Reservoir r;
        r.s.currentSampleId = p.IdAndM.x;
        r.M = p.IdAndM.y;
        r.targetPdfSample = asfloat(p.targetPdfSampleWSum.xyz);
        r.wSum = asfloat(p.targetPdfSampleWSum.w);
        r.s.type = p.type;
        return r;
    }
}

// struct CombinedReservoirFactory
// {
//     Reservoir master;
//     uint M;
//     __init()
//     {
//         master = Reservoir();
//         M = 0;
//     }
//     // Fix Weight
//     [mutating]
//     bool update(Reservoir ri, float3 newPdfSample)
//     {
//         M += ri.M;
//         float fixedW = ri.wSum * length(newPdfSample) / length(ri.targetPdfSample);
//         return master.update(ri.currentSampleId, fixedW, newPdfSample, randSimple((ri.targetPdfSample.x, ri.wSum)));
//     }
//     [mutating]
//     bool update(Reservoir ri)
//     {
//         M += ri.M;
//         return master.update(ri.currentSampleId, ri.wSum, ri.targetPdfSample, randSimple((ri.targetPdfSample.x, ri.wSum)));
//     }
//     [mutating]
//     Reservoir getCombinedReservoir()
//     {
//         master.M = M;
//         return master;
//     }
// }
