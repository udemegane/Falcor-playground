add_renderpass(TinyPathTracer)

target_sources(TinyPathTracer PRIVATE
        TinyPathTracer.cpp
        TinyPathTracer.h
        TinyPathTracer.rt.slang
        )

target_copy_shaders(TinyPathTracer RenderPasses/TinyPathTracer)

target_source_group(TinyPathTracer "RenderPasses")
