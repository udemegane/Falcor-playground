from falcor import *

def render_graph_ReSTIRTAA():
    g = RenderGraph('ReSTIR')
    loadRenderPassLibrary('Antialiasing.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('ReSTIR.dll')
    ReSTIR = createPass('ReSTIR', {'temporalReuseMaxM': 20, 'risSampleNums': 8, 'autoSetMaxM': True, 'useReSTIR': True, 'useTemporalReuse': True, 'useSpatialReuse': True, 'spatialRadius': 5, 'spatialNeighbors': 4, 'useFixWeight': True})
    g.addPass(ReSTIR, 'ReSTIR')
    VBufferRT = createPass('VBufferRT', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 8, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'useTraceRayInline': False, 'useDOF': True})
    g.addPass(VBufferRT, 'VBufferRT')
    TAA = createPass('TAA', {'alpha': 0.10000000149011612, 'colorBoxSigma': 1.0})
    g.addPass(TAA, 'TAA')
    g.addEdge('VBufferRT.mvec', 'ReSTIR.motionVecW')
    g.addEdge('VBufferRT.vbuffer', 'ReSTIR.vBuffer')
    g.addEdge('VBufferRT.viewW', 'ReSTIR.viewW')
    g.addEdge('VBufferRT.depth', 'ReSTIR.depth')
    g.addEdge('VBufferRT.mvec', 'TAA.motionVecs')
    g.addEdge('ReSTIR.color', 'TAA.colorIn')
    g.markOutput('TAA.colorOut')
    return g

ReSTIRTAA = render_graph_ReSTIRTAA()
try: m.addGraph(ReSTIRTAA)
except NameError: None
