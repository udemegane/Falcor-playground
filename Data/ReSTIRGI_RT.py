from falcor import *

def render_graph_ReSTIRGIaccum():
    g = RenderGraph('ReSTIRGIaccum')
    ImageLoader = createPass('ImageLoader', {'outputSize': IOSize.Default, 'outputFormat': ResourceFormat.BGRA8UnormSrgb, 'filename': 'E:/Falcor/Source/RenderPasses/Falcor-playground/Data/FreeBlueNoiseTextures/Data/1024_1024/LDR_RGBA_0.png', 'mips': False, 'srgb': True, 'arrayIndex': 0, 'mipLevel': 0})
    g.addPass(ImageLoader, 'ImageLoader')
    ToneMapper = createPass('ToneMapper', {'outputSize': IOSize.Default, 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': ToneMapOp.Aces, 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': ExposureMode.AperturePriority})
    g.addPass(ToneMapper, 'ToneMapper')
    ReSTIRGIPass = createPass('ReSTIRGIPass')
    g.addPass(ReSTIRGIPass, 'ReSTIRGIPass')
    AccumulatePass = createPass('AccumulatePass', {'enabled': False, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Single, 'maxFrameCount': 0, 'overflowMode': AccumulateOverflowMode.Stop})
    g.addPass(AccumulatePass, 'AccumulatePass')
    GBufferRT = createPass('GBufferRT', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack, 'texLOD': TexLODMode.Mip0, 'useTraceRayInline': False, 'useDOF': True})
    g.addPass(GBufferRT, 'GBufferRT')
    g.addEdge('ImageLoader.dst', 'ReSTIRGIPass.noiseTex')
    g.addEdge('ReSTIRGIPass.color', 'AccumulatePass.input')
    g.addEdge('AccumulatePass.output', 'ToneMapper.src')
    g.addEdge('GBufferRT.vbuffer', 'ReSTIRGIPass.vBuffer')
    g.addEdge('GBufferRT.mvec', 'ReSTIRGIPass.motionVector')
    g.addEdge('GBufferRT.depth', 'ReSTIRGIPass.depth')
    g.addEdge('GBufferRT.normW', 'ReSTIRGIPass.normal')
    g.markOutput('ToneMapper.dst')
    return g

ReSTIRGIaccum = render_graph_ReSTIRGIaccum()
try: m.addGraph(ReSTIRGIaccum)
except NameError: None
