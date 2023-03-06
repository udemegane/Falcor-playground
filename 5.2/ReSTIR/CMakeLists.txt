add_plugin(ReSTIR)

target_sources(ReSTIR PRIVATE
    ReSTIR.cpp
    ReSTIR.h
    RaytraceUtils.slang
    WRSTracer.rt.slang
    WRS.cs.slang
    Reservoir.slang
    SpatioTemporalReuse.cs.slang
)

target_copy_shaders(ReSTIR RenderPasses/ReSTIR)

target_source_group(ReSTIR "RenderPasses")
