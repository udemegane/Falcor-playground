from falcor import *

def render_graph_DefaultRenderGraph():
    g = RenderGraph('DefaultRenderGraph')
    ImageLoader = createPass('ImageLoader', {'outputSize': IOSize.Default, 'filename': 'C:/Users/cappu/Documents/workspace/Falcor_2/Source/RenderPasses/Falcor-playground/Data/FreeBlueNoiseTextures/Data/1024_1024/LDR_RGBA_0.png', 'mips': False, 'srgb': True, 'arrayIndex': 0, 'mipLevel': 0})
    g.addPass(ImageLoader, 'ImageLoader')
    GBufferRaster = createPass('GBufferRaster', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack})
    g.addPass(GBufferRaster, 'GBufferRaster')
    ToneMapper = createPass('ToneMapper', {'outputSize': IOSize.Default, 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': ToneMapOp.Aces, 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': ExposureMode.AperturePriority})
    g.addPass(ToneMapper, 'ToneMapper')
    ReSTIRGIPass = createPass('ReSTIRGIPass')
    g.addPass(ReSTIRGIPass, 'ReSTIRGIPass')
    g.addEdge('GBufferRaster.vbuffer', 'ReSTIRGIPass.vBuffer')
    g.addEdge('GBufferRaster.mvec', 'ReSTIRGIPass.motionVector')
    g.addEdge('GBufferRaster.depth', 'ReSTIRGIPass.depth')
    g.addEdge('GBufferRaster.normW', 'ReSTIRGIPass.normal')
    g.addEdge('ImageLoader.dst', 'ReSTIRGIPass.noiseTex')
    g.markOutput('ReSTIRGIPass.color')
    return g

DefaultRenderGraph = render_graph_DefaultRenderGraph()
try: m.addGraph(DefaultRenderGraph)
except NameError: None
