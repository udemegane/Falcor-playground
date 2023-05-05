add_plugin(ReSTIRDIPass)

target_sources(ReSTIRDIPass PRIVATE
    ReSTIRDIPass.cpp
    ReSTIRDIPass.h
    ReflectTypes.cs.slang
    PrepareReservoir.cs.slang
    FinalShading.cs.slang
    LoadShadingData.slang
    RaytracingUtils.slang
    Reservoir.slang
    Params.slang
    StaticParams.slang
)
target_copy_shaders(ReSTIRDIPass RenderPasses/ReSTIRDIPass)

target_source_group(ReSTIRDIPass "RenderPasses")
