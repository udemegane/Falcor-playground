add_renderpass(ReSTIR)

target_sources(ReSTIR PRIVATE
    ReSTIR.rt.slang
    ReSTIR.cpp
    ReSTIR.h
)

target_copy_shaders(ReSTIR RenderPasses/ReSTIR)

target_source_group(ReSTIR "RenderPasses")
