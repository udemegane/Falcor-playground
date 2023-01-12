add_renderpass(WireframePass)

target_sources(WireframePass PRIVATE
    WireframePass.cpp
        WireframePass.h
    WireframePass.3d.slang
)
target_copy_shaders(WireframePass RenderPasses/WireframePass)

target_source_group(WireframePass "RenderPasses")
