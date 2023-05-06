#include "Utils/Math/MathConstants.slangh"
import Utils.Math.PackedFormats;
import Utils.Color.ColorHelpers;
struct Sample
{
    float3 Li; // already multiply invPdf.
    float3 dir;
    float length;
    __init()
    {
        Li = float3(0.f);
        dir = float3(0.f);
        length = 0.f;
    }
}

struct PackedReservoir
{
    // 128bit x2
    uint4 pTargetLi;
    float2 LengthWsum;
    uint2 MDir;
}

struct Reservoir
{
    float wSum;
    Sample s;
    float targetPdfSample;
    uint M;
    __init()
    {
        wSum = 0;
        M = 0;
        s = Sample();
        targetPdfSample = 0.f;
    }
    [mutating]
    bool update(const Sample s, const float wi, const float pi, const float rand)
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

    float getInvPDF() { return (wSum + HLF_EPSILON) / (M * targetPdfSample + HLF_EPSILON); }

    PackedReservoir pack()
    {
        PackedReservoir p;
        p.pTargetLi.x = asuint(targetPdfSample);
        p.pTargetLi.yzw = asuint(s.Li);
        encodeNormal2x16(s.dir);
        p.LengthWsum.x = s.length;
        p.LengthWsum.y = wSum;
        p.MDir = encodeNormal3x16(s.dir);
        p.MDir.y = (M << 16) | p.MDir.y;
        return p;
    }

    [mutating]
    bool merge(const in Reservoir ri, const float pi, const float u)
    {
        uint M1 = this.M;
        float fixedW = ri.wSum * (targetPdfSample) / (ri.targetPdfSample);
        bool accept = update(ri.s, fixedW, pi, u);
        this.M = M1 + ri.M;
        return accept;
    }

    static Reservoir unpack(PackedReservoir p)
    {
        Reservoir r;
        r.s.Li = asfloat(p.pTargetLi.yzw);
        uint bitfrag = p.MDir.y;
        r.M = (bitfrag >> 16) & 0xffff;
        r.targetPdfSample = asfloat(p.pTargetLi.x);
        r.s.dir = decodeNormal3x16(p.MDir);
        r.s.length = p.LengthWsum.x;
        r.wSum = p.LengthWsum.y;
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
