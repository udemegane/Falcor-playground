// Input
RWTexture2D<float4> gShadingColor;
RWTexture2D<float> gShadow;
// Output
RWTexture2D<float4> gOutColor;

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    gOutColor[pixel] = (gShadingColor[pixel].xyz * gShadow[pixel], 1.0f);
}
