add_renderpass(HybridRaytracing)

target_sources(HybridRaytracing PRIVATE
    HybridRaytracing.cpp
    HybridRaytracing.h
    HybridPathtrace.cs.slang
    TraceRay.slang
)
target_copy_shaders(HybridRaytracing RenderPasses/HybridRaytracing)
target_source_group(HybridRaytracing "RenderPasses")
