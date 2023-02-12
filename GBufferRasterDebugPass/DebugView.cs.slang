
Texture2D<float> gDepth;
Texture2D<float4> gPosW;
Texture2D<float4> gNormW;
Texture2D<float4> gTangentW;
Texture2D<float4> gFaceNormalW;
Texture2D<float2> gTexC;
Texture2D<float4> gTexGrads;
Texture2D<float2> gMotionVector;
Texture2D<float4> gMaterialData;
Texture2D gVBuffer;
Texture2D<float4> gDiffOpacity;
Texture2D<float4> gSpecRough;
Texture2D<float4> gEmissive;
Texture2D<float4> gViewW;
Texture2D<float2> gPosNormalFwidth;
Texture2D<float2> gLinearZ;

cbuffer PerFrameCB
{
    uint2 frameDim;
}

enum class DebugMode : uint32_t
{
    Depth,
    PosW,
    NormW,
    TangentW,
    FaceNormalW,
    TexCoord,
    TexGrad,
    MotionVec,
    MaterialData,
    VBuffer,
    DiffuseOpacity,
    SpecRough,
    Emissive,
    ViewW,
    PosAndNormWidth,
    LinearZ,
    TileColor,
};

RWTexture2D<float4> gOutColor;
static const uint32_t gDebugMode = DEBUG_MODE;

void fillTile1Color(uint2 pixel, uint3 groupId)
{
    uint x = groupId.x / 8;
    uint y = groupId.y / 8;
    uint maxX = (frameDim.x + 127) / 128;
    uint maxY = (frameDim.y + 127) / 128;
    gOutColor[pixel] = float4(float(x / maxX), 0.f, float(y / maxY), 1.0f);
}

[numthreads(16, 16, 1)]
void main(uint3 groupId: SV_GroupID, uint3 groupThreadId: SV_GroupThreadID, uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (all(pixel >= frameDim))
        return;
    gOutColor[pixel] = float4(1.0, 0.f, 0.f, 1.0);
    switch (gDebugMode)
    {
    case DebugMode.Depth:
        gOutColor[pixel] = float4(gDepth[pixel]);
    case DebugMode.PosW:
        gOutColor[pixel] = gPosW[pixel];
    case DebugMode.NormW:
        gOutColor[pixel] = gNormW[pixel];
    case DebugMode.TangentW:
        gOutColor[pixel] = gTangentW[pixel];
    case DebugMode.TileColor:
        fillTile1Color(pixel, groupId);
    default:
        fillTile1Color(pixel, groupId);
    }
}
