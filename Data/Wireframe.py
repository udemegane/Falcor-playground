from falcor import *

def render_graph_WireframePass():
    g = RenderGraph('Wireframe')
    WireframePass = createPass('WireframePass')
    g.addPass(WireframePass, 'WireframePass')
    g.markOutput('WireframePass.output')
    return g

Wireframe= render_graph_WireframePass()
try: m.addGraph(Wireframe)
except NameError: None
