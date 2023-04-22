struct GISample
{
    float3 xv;
    float3 nv;
    float3 xs;
    float3 ns;
    float3 Lo;
    float invPdf;
    float rand;
}

struct GIReservoir
{
    GISample s;
    float wSum;
    uint M;
    // uint updateCounts;
    float3 ps; // Pdf(Sample)
    __init()
    {
        wSum = 0.f;
        M = 0;
        // updateCounts = 0;
        ps = 0.f;
    }

    [mutating]
    bool update(const GISample si, const float wi, const float u)
    {
        wSum += wi;
        bool accept = u <= wi / wSum;
        if (accept || M == 0)
        {
            s = si;
            ps = si.Lo;
            // updateCounts++;
        }
        M++;
        return accept;
    }

    [mutating]
    void merge(GIReservoir ri, float p)
    {
        uint tempM = M;
        float fixedW = ri.wSum * (p / length(ps));
        update(ri.s, fixedW, ri.s.rand);
        M = tempM + ri.M;
    }

    float getInvPDF() { return wSum / (M * length(ps)); }
}

