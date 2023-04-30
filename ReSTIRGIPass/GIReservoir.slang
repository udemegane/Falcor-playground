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
    float sceneLength;
    float3 debug;
    __init()
    {
        xv = float3(0.f);
        nv = float3(0.f);
        xs = float3(0.f);
        ns = float3(0.f);
        Lo = float3(0.f);
        weight = float3(1.f);
        invPdf = 1.f;
        sceneLength = 0.f;
        debug = float3(0.f);
    }
}

struct GIReservoir
{
    GISample s;
    float wSum;
    uint M;
    bool updated;
    float ps; // Pdf(Sample)
    __init()
    {
        wSum = 0.f;
        M = 0;
        updated = false;
        ps = 0.f;
    }

    // [mutating] bool update(const GISample si, const float wi, const float u)
    // {
    //     wSum += wi;
    //     bool accept = u <= (wi + HLF_EPSILON) / (wSum + HLF_EPSILON);
    //     if (accept || M == 0)
    //     {
    //         s = si;
    //         ps = length(si.Lo) * si.invPdf;
    //     }
    //     M++;
    //     return accept;
    // }

    //     [mutating] bool merge(GIReservoir ri, float p, float u)
    // {
    //     uint tempM = M;
    //     float fixedW = ri.wSum * ((p * ri.s.invPdf + HLF_EPSILON) / (ps + HLF_EPSILON));
    //     bool accept = update(ri.s, fixedW, u);
    //     M = tempM + ri.M;
    //     return accept;
    // }

    // float getInvPDF() { return (wSum + HLF_EPSILON) / (M * ps + HLF_EPSILON); }
}

float getInvPDF(const in GIReservoir r)
{
    return (r.wSum + DBL_EPSILON) / (r.M * r.ps + DBL_EPSILON);
}

bool updateReservoir(inout GIReservoir r, const in GISample si, const float wi, const float u)
{
    r.wSum += wi;
    bool accept = u <= (wi + HLF_EPSILON) / (r.wSum + HLF_EPSILON);
    if (accept || r.M == 0)
    {
        r.s = si;
        r.ps = length(si.Lo) * si.invPdf;
    }
    r.M++;
    return accept;
}

bool mergeReservoirs(inout GIReservoir r1, const in GIReservoir r2, const float p2, const float u)
{
    uint M1 = r1.M;
    float fixedW = r2.wSum * (p2 + HLF_EPSILON) / (r2.ps + HLF_EPSILON);
    bool accept = updateReservoir(r1, r2.s, fixedW, u); // r1.update(r2.s, fixedW, u);
    r1.M = M1 + r2.M;
    return accept;
}

void setVisibilityPoint(inout GIReservoir r, const GISample dst)
{
    r.s.xv = dst.xv;
    r.s.nv = dst.nv;
    // r.s.weight = dst.weight;
    // r.s.invPdf = dst.invPdf;
}
