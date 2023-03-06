from falcor import *

def render_graph_VisibilityRenderingDenoise():
    g = RenderGraph('VisibilityRenderingDenoise')
    loadRenderPassLibrary('Antialiasing.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('VisibilityRenderPass.dll')
    VisibilityRenderPass = createPass('VisibilityRenderPass', {'combineShadow': True, 'RISSamples': 8, 'useTemporalReuse': True})
    g.addPass(VisibilityRenderPass, 'VisibilityRenderPass')
    VBufferRT = createPass('VBufferRT', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'useTraceRayInline': False, 'useDOF': True})
    g.addPass(VBufferRT, 'VBufferRT')
    TAA = createPass('TAA', {'alpha': 0.10000000149011612, 'colorBoxSigma': 1.0})
    g.addPass(TAA, 'TAA')
    g.addEdge('VBufferRT.vbuffer', 'VisibilityRenderPass.vBuffer')
    g.addEdge('VBufferRT.depth', 'VisibilityRenderPass.depth')
    g.addEdge('VBufferRT.mvec', 'VisibilityRenderPass.motionVecW')
    g.addEdge('VBufferRT.viewW', 'VisibilityRenderPass.viewW')
    g.addEdge('VisibilityRenderPass.color', 'TAA.colorIn')
    g.addEdge('VBufferRT.mvec', 'TAA.motionVecs')
    g.markOutput('TAA.colorOut')
    return g

VisibilityRenderingDenoise = render_graph_VisibilityRenderingDenoise()
try: m.addGraph(VisibilityRenderingDenoise)
except NameError: None
