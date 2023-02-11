add_renderpass(GBufferRasterDebugPass)

target_sources(GBufferRasterDebugPass PRIVATE
    GBufferRasterDebugPass.cpp
    GBufferRasterDebugPass.h
)

target_source_group(GBufferRasterDebugPass "RenderPasses")
