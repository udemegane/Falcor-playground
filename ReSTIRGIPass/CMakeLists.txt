add_plugin(ReSTIRGIPass)

target_sources(ReSTIRGIPass PRIVATE
    ReSTIRGIPass.cpp
    ReSTIRGIPass.h
    EvaluateSample.cs.slang
    PrepareReservoir.cs.slang
    GIReservoir.slang
    StaticParams.slang
    RaytracingUtils.slang
    LoadShadingData.slang
)

target_copy_shaders(ReSTIRGIPass RenderPasses/ReSTIRGIPass)

target_source_group(ReSTIRGIPass "RenderPasses")
