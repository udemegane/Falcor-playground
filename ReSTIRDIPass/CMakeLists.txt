add_plugin(ReSTIRDIPass)

target_sources(ReSTIRDIPass PRIVATE
    ReSTIRDIPass.cpp
    ReSTIRDIPass.h
)

target_source_group(ReSTIRDIPass "RenderPasses")
