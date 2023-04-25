add_plugin(ReSTIRGIPass)

target_sources(ReSTIRGIPass PRIVATE
    ReSTIRGIPass.cpp
    ReSTIRGIPass.h
    InitialSampling.cs.slang
    TemporalResampling.cs.slang
    SpatialResampling.cs.slang
    FinalShading.cs.slang
    GIReservoir.slang
    StaticParams.slang
    RaytracingUtils.slang
)

target_copy_shaders(ReSTIRGIPass RenderPasses/ReSTIRGIPass)

target_source_group(ReSTIRGIPass "RenderPasses")
