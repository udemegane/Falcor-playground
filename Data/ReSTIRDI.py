from falcor import *

def render_graph_ReSTIRDIPass():
    g = RenderGraph('ReSTIRDI')
    VBufferRT = createPass('VBufferRT', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'useTraceRayInline': False, 'useDOF': True})
    g.addPass(VBufferRT, 'VBufferRT')
    ReSTIRDIPass = createPass('ReSTIRDIPass', {'temporalReuseMaxM': 20, 'risSampleNums': 8, 'autoSetMaxM': True, 'useReSTIR': True, 'useTemporalReuse': True, 'useSpatialReuse': True, 'spatialRadius': 5, 'spatialNeighbors': 4})
    g.addPass(ReSTIRDIPass, 'ReSTIRDIPass')
    ToneMapper = createPass('ToneMapper', {'outputSize': IOSize.Default, 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': ToneMapOp.Aces, 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': ExposureMode.AperturePriority})
    g.addPass(ToneMapper, 'ToneMapper')
    AccumulatePass = createPass('AccumulatePass', {'enabled': True, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Single, 'maxFrameCount': 0, 'overflowMode': AccumulateOverflowMode.Stop})
    g.addPass(AccumulatePass, 'AccumulatePass')
    g.addEdge('VBufferRT.vbuffer', 'ReSTIRDIPass.vBuffer')
    g.addEdge('VBufferRT.mvec', 'ReSTIRDIPass.motionVecW')
    g.addEdge('VBufferRT.viewW', 'ReSTIRDIPass.viewW')
    g.addEdge('VBufferRT.depth', 'ReSTIRDIPass.depth')
    g.addEdge('ReSTIRDIPass.color', 'AccumulatePass.input')
    g.addEdge('AccumulatePass.output', 'ToneMapper.src')
    g.markOutput('ToneMapper.dst')
    return g

ReSTIRDIPass = render_graph_ReSTIRDIPass()
try: m.addGraph(ReSTIRDIPass)
except NameError: None
