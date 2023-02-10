add_renderpass(ReSTIR)

target_sources(ReSTIR PRIVATE
        ReSTIR.cpp
        ReSTIR.h
        WRSTracer.rt.slang
        WRSTracer.cs.slang
        Reservoir.slang
        SpatioTemporalReuse.cs.slang
        )

target_copy_shaders(ReSTIR RenderPasses/ReSTIR)

target_source_group(ReSTIR "RenderPasses")
