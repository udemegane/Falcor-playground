add_renderpass(VisibilityRenderPass)

target_sources(VisibilityRenderPass PRIVATE
    VisibilityRenderPass.cpp
    VisibilityRenderPass.h
    Combine.cs.slang
    ReSTIRShadow.cs.slang
    Shading.cs.slang
)
target_copy_shaders(VisibilityRenderPass RenderPasses/VisibilityRenderPass)
target_source_group(VisibilityRenderPass "RenderPasses")
