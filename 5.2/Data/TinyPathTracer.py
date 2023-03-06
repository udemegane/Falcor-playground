from falcor import *

def render_graph_TinyPathTracer():
    g = RenderGraph("TinyPathTracer")
    loadRenderPassLibrary("AccumulatePass.dll")
    loadRenderPassLibrary("GBuffer.dll")
    loadRenderPassLibrary("TinyPathTracer.dll")
    loadRenderPassLibrary("ToneMapper.dll")
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': AccumulatePrecision.Single})
    g.addPass(AccumulatePass, "AccumulatePass")
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")
    TinyPathTracer = createPass("TinyPathTracer", {'maxBounces': 3})
    g.addPass(TinyPathTracer, "TinyPathTracer")
    VBufferRT = createPass("VBufferRT", {'samplePattern': SamplePattern.Stratified, 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    g.addEdge("AccumulatePass.output", "ToneMapper.src")
    g.addEdge("VBufferRT.vbuffer", "TinyPathTracer.vbuffer")
    g.addEdge("VBufferRT.viewW", "TinyPathTracer.viewW")
    g.addEdge("TinyPathTracer.color", "AccumulatePass.input")
    g.markOutput("ToneMapper.dst")
    return g

TinyPathTracer = render_graph_TinyPathTracer()
try: m.addGraph(TinyPathTracer)
except NameError: None
