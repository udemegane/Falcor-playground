from falcor import *

def render_graph_VisibilityRendering():
    g = RenderGraph('VisibilityRendering')
    loadRenderPassLibrary('Antialiasing.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('SVGFPass.dll')
    loadRenderPassLibrary('VisibilityRenderPass.dll')
    VisibilityRenderPass = createPass('VisibilityRenderPass', {'combineShadow': True, 'RISSamples': 8, 'useTemporalReuse': True})
    g.addPass(VisibilityRenderPass, 'VisibilityRenderPass')
    VBufferRT = createPass('VBufferRT', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'useTraceRayInline': False, 'useDOF': True})
    g.addPass(VBufferRT, 'VBufferRT')
    g.addEdge('VBufferRT.vbuffer', 'VisibilityRenderPass.vBuffer')
    g.addEdge('VBufferRT.depth', 'VisibilityRenderPass.depth')
    g.addEdge('VBufferRT.mvec', 'VisibilityRenderPass.motionVecW')
    g.addEdge('VBufferRT.viewW', 'VisibilityRenderPass.viewW')
    g.markOutput('VisibilityRenderPass.shading')
    return g

VisibilityRendering = render_graph_VisibilityRendering()
try: m.addGraph(VisibilityRendering)
except NameError: None
