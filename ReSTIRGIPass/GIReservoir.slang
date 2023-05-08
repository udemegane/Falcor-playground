#include "Utils/Math/MathConstants.slangh"
import Utils.Math.PackedFormats;
import Utils.Color.ColorHelpers;

struct PackedGIReservoir
{
    // 128bit x5
    // Maybe it's too heavy?
    float4 LoSceneLength;
    float4 weightInvPdf;
    float4 XvWSum;
    float4 XsPTarget;
    uint4 NvMNsUpdated;
}
struct GISample
{
    float3 xv;         //
    float3 nv;         //
    float3 xs;         //
    float3 ns;         //
    float3 Lo;         //
    float3 weight;     //
    float invPdf;      //
    float sceneLength; //
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
    }
}

struct GIReservoir
{
    GISample s; //
    float wSum; //
    uint M;
    bool updated;
    float ps; // Pdf(Sample) //
    __init()
    {
        wSum = 0.f;
        M = 0;
        updated = false;
        ps = 0.f;
    }

    PackedGIReservoir pack()
    {
        PackedGIReservoir p;
        p.LoSceneLength = float4(s.Lo, s.sceneLength);
        p.weightInvPdf = float4(s.weight, s.invPdf);
        p.XvWSum = float4(s.xv, wSum);
        p.XsPTarget = float4(s.xs, ps);
        uint2 packedNv = encodeNormal3x16(s.nv);
        uint2 packedNs = encodeNormal3x16(s.ns);
        uint tempM = M;
        packedNv.y = (tempM << 16) | packedNv.y;
        uint tempUpdated = updated ? 1u : 0u;
        packedNs.y = (tempUpdated << 16) | packedNs.y;
        p.NvMNsUpdated.x = packedNv.x;
        p.NvMNsUpdated.y = packedNv.y;
        p.NvMNsUpdated.z = packedNs.x;
        p.NvMNsUpdated.w = packedNs.y;
        return p;
    }
    static GIReservoir unpack(PackedGIReservoir p)
    {
        GIReservoir r = GIReservoir();
        r.s.Lo = p.LoSceneLength.xyz;
        r.s.sceneLength = p.LoSceneLength.w;
        r.s.xv = p.XvWSum.xyz;
        r.wSum = p.XvWSum.w;
        r.s.xs = p.XsPTarget.xyz;
        r.ps = p.XsPTarget.w;
        uint bitfrag1 = p.NvMNsUpdated.y;
        r.M = (bitfrag1 >> 16) & 0xffff;
        uint bitfrag2 = p.NvMNsUpdated.w;
        r.updated = ((bitfrag2 >> 16) & 0xffff) == 1u ? true : false;
        r.s.nv = decodeNormal3x16(p.NvMNsUpdated.xy);
        r.s.ns = decodeNormal3x16(p.NvMNsUpdated.zw);
        return r;
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
        r.ps = luminance(si.Lo) * si.invPdf;
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
}
