from falcor import *

def render_graph_ReSTIR():
    g = RenderGraph('ReSTIR')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('SVGFPass.dll')
    loadRenderPassLibrary('ReSTIR.dll')
    ReSTIR = createPass('ReSTIR', {'risSampleNums': 8, 'useReSTIR': True, 'useTemporalReuse': False, 'useSpatialReuse': False})
    g.addPass(ReSTIR, 'ReSTIR')
    VBufferRT = createPass('VBufferRT', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 8, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'useTraceRayInline': False, 'useDOF': True})
    g.addPass(VBufferRT, 'VBufferRT')
    AccumulatePass = createPass('AccumulatePass', {'enabled': False, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Single, 'subFrameCount': 0, 'maxAccumulatedFrames': 0})
    g.addPass(AccumulatePass, 'AccumulatePass')
    g.addEdge('VBufferRT.mvec', 'ReSTIR.motionVecW')
    g.addEdge('VBufferRT.vbuffer', 'ReSTIR.vBuffer')
    g.addEdge('VBufferRT.viewW', 'ReSTIR.viewW')
    g.addEdge('ReSTIR.color', 'AccumulatePass.input')
    g.markOutput('AccumulatePass.output')
    return g

ReSTIR = render_graph_ReSTIR()
try: m.addGraph(ReSTIR)
except NameError: None
