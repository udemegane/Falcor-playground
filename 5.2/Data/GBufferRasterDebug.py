from falcor import *

def render_graph_GBufferDebugView():
    g = RenderGraph('GBufferDebugView')
    loadRenderPassLibrary('DebugPasses.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('GBufferRasterDebugPass.dll')
    GBufferRaster = createPass('GBufferRaster', {'outputSize': IOSize.Default, 'samplePattern': SamplePattern.Center, 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': CullMode.CullBack})
    g.addPass(GBufferRaster, 'GBufferRaster')
    GBufferRasterDebugPass = createPass('GBufferRasterDebugPass')
    g.addPass(GBufferRasterDebugPass, 'GBufferRasterDebugPass')
    g.addEdge('GBufferRaster.depth', 'GBufferRasterDebugPass.depth')
    g.addEdge('GBufferRaster.posW', 'GBufferRasterDebugPass.posW')
    g.addEdge('GBufferRaster.normW', 'GBufferRasterDebugPass.normW')
    g.addEdge('GBufferRaster.tangentW', 'GBufferRasterDebugPass.tangentW')
    g.addEdge('GBufferRaster.faceNormalW', 'GBufferRasterDebugPass.faceNormalW')
    g.addEdge('GBufferRaster.texC', 'GBufferRasterDebugPass.texCoord')
    g.addEdge('GBufferRaster.texGrads', 'GBufferRasterDebugPass.texGrad')
    g.addEdge('GBufferRaster.mvec', 'GBufferRasterDebugPass.motionVec')
    g.addEdge('GBufferRaster.mtlData', 'GBufferRasterDebugPass.materialData')
    g.addEdge('GBufferRaster.vbuffer', 'GBufferRasterDebugPass.vBuffer')
    g.addEdge('GBufferRaster.diffuseOpacity', 'GBufferRasterDebugPass.diffuseOpacity')
    g.addEdge('GBufferRaster.specRough', 'GBufferRasterDebugPass.specRough')
    g.addEdge('GBufferRaster.emissive', 'GBufferRasterDebugPass.emissive')
    g.addEdge('GBufferRaster.viewW', 'GBufferRasterDebugPass.viewW')
    g.addEdge('GBufferRaster.pnFwidth', 'GBufferRasterDebugPass.posAndNormWidth')
    g.addEdge('GBufferRaster.linearZ', 'GBufferRasterDebugPass.linearZ')
    g.markOutput('GBufferRasterDebugPass.output')
    return g

GBufferDebugView = render_graph_GBufferDebugView()
try: m.addGraph(GBufferDebugView)
except NameError: None
