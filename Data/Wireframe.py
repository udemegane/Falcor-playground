from falcor import *

def render_graph_WireframePass():
    g = RenderGraph('WireframePass')
    #loadRenderPassLibrary('WireframePass.dll')
    Wireframe = createPass('WireframePass')
    g.addPass(WireframePass, 'WireframePass')
    g.markOutput('WireframePass.output')
    return g

WireframePass = render_graph_WireframePass()
try: m.addGraph(WireframePass)
except NameError: None
