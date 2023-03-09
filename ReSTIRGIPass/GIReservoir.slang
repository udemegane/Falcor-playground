struct GISample{
    float3 xv;
    float3 nv;
    float3 xs;
    float3 ns;
    float3 Lo;
    float rand;
}

struct GIReservoir{
    GISample s;
    float wSum;
    uint M;
    float3 ps;
    float normedPs;

    [mutating]
    bool update(const GISample si,const float wi, const float3 pi){
        wSum+=wi;
        bool accept = si.rand<=wi/wSum;
        if(accept||M==0){
            s=si;
            ps=pi;
            normedPs=length(ps);
        }
        M++;
        return accept;
    }

    [mutating]
    void merge(GIReservoir ri, float3 pi){
        uint tempM = M;
        float fixedW=ri.wSum * (length(pi)/normedPs);
        update(ri.s, fixedW, pi);
        M=tempM+ri.M;
    }

    float getInvPDF(){
        return wSum/(M*normedPs);
    }
}

