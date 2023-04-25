#include "Utils/Math/MathConstants.slangh"
struct GISample
{
    float3 xv;
    float3 nv;
    float3 xs;
    float3 ns;
    float3 Lo;
    float3 weight;
    float invPdf;
    __init()
    {
        xv = float3(0.f);
        nv = float3(0.f);
        xs = float3(0.f);
        ns = float3(0.f);
        Lo = float3(0.f);
        weight = float3(0.f);
        invPdf = 0.f;
    }
}

struct GIReservoir
{
    GISample s;
    float wSum;
    uint M;
    bool dummy;
    bool updated;
    float ps; // Pdf(Sample)
    __init()
    {
        dummy = true;
        wSum = 0.f;
        M = 0;
        updated = false;
        ps = 0.f;
    }

    [mutating] bool update(const GISample si, const float wi, const float u)
    {
        wSum += wi;
        bool accept = u <= (wi + HLF_EPSILON) / (wSum + HLF_EPSILON);
        if (accept || M == 0)
        {
            s = si;
            ps = length(si.Lo) * si.invPdf;
        }
        M++;
        return accept;
    }

        [mutating] bool merge(GIReservoir ri, float p, float u)
    {
        uint tempM = M;
        float fixedW = ri.wSum * ((p * ri.s.invPdf + HLF_EPSILON) / (ps + HLF_EPSILON));
        bool accept = update(ri.s, fixedW, u);
        M = tempM + ri.M;
        return accept;
    }

    float getInvPDF() { return (wSum + HLF_EPSILON) / (M * ps + HLF_EPSILON); }
}
