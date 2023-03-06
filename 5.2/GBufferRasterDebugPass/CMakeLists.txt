add_plugin(GBufferRasterDebugPass)

target_sources(GBufferRasterDebugPass PRIVATE
    GBufferRasterDebugPass.cpp
    GBufferRasterDebugPass.h
    DebugView.cs.slang
)

target_copy_shaders(GBufferRasterDebugPass RenderPasses/GBufferRasterDebugPass)
target_source_group(GBufferRasterDebugPass "RenderPasses")
