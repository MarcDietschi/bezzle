# alive_onnx.py <model.onnx> [more.onnx …]
# What a model keeps alive at its peak when ONNX Runtime runs it on the processor as Windows does
# (matte.cpp: basic optimizations, no arena): it runs the model once with ONNX Runtime's own record
# of every layer switched on, which says what each layer made and how large, and adds up what is
# alive after each layer, in the order ONNX Runtime ran them, letting go of each output after the
# last layer that reads it, as ONNX Runtime does. It prints the peak, where it is and what holds it.
#
# This is the memory the model needs, whatever the allocator: a process's footprint on a Mac says
# more, since macOS keeps freed memory a while, and a PC short of memory says less, since it pages
# (the VM's 10 GB at 2,048 pixels was its own limit). See README.md, "For Windows".
import sys, os, json, tempfile, time
from collections import defaultdict
import numpy as np
import onnx
import onnxruntime as ort

WIDTH = {'float': 4, 'float16': 2, 'double': 8, 'int64': 8, 'int32': 4, 'int8': 1, 'uint8': 1, 'bool': 1}


def alive(path):
    work = tempfile.mkdtemp()
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    options.enable_cpu_mem_arena = False
    options.enable_profiling = True
    options.profile_file_prefix = os.path.join(work, 'record')
    # The graph as ONNX Runtime runs it, its layers named as the record names them.
    options.optimized_model_filepath = os.path.join(work, 'as-run.onnx')
    session = ort.InferenceSession(path, options, providers=['CPUExecutionProvider'])
    side = session.get_inputs()[0].shape[-1]
    began = time.time()
    session.run(None, {session.get_inputs()[0].name: np.random.rand(1, 3, side, side).astype(np.float32)})
    took = time.time() - began
    record = json.load(open(session.end_profiling()))
    graph = onnx.load(options.optimized_model_filepath, load_external_data=False).graph
    nodes = {node.name: node for node in graph.node}

    order, size = [], {}
    for event in record:
        if event.get('cat') != 'Node' or not event['name'].endswith('_kernel_time'):
            continue
        node = nodes.get(event['name'][:-len('_kernel_time')])
        if node is None:
            continue
        order.append(node)
        for out, made in zip([o for o in node.output if o], event['args'].get('output_type_shape', [])):
            (kind, dims), = made.items()
            size[out] = (int(np.prod(dims)) if dims else 1) * WIDTH.get(kind, 4), dims, node

    last = {}
    for k, node in enumerate(order):
        for name in node.input:
            last[name] = k
    for out in graph.output:
        last[out.name] = len(order)
    let_go = defaultdict(list)
    for name, k in last.items():
        let_go[k].append(name)

    now, peak, at, held, living = 0, 0, 0, {}, {}
    for k, node in enumerate(order):
        for out in node.output:
            if out in size and out in last:
                living[out] = size[out][0]
                now += size[out][0]
        if now > peak:
            peak, at, held = now, k, dict(living)
        for name in let_go[k]:
            now -= living.pop(name, 0)

    print(f'{os.path.basename(path)} at {side} pixels: {peak / 1e9:.2f} GB alive at the peak, at layer {at + 1} of {len(order)} '
          f'({order[at].op_type} {order[at].name[-60:]}); the matte took {took:.1f} s with the record on')
    kinds = defaultdict(int)
    for name, bytes_ in held.items():
        kinds[size[name][2].op_type] += bytes_
    print('  held by: ' + ', '.join(f'{kind} {bytes_ / 1e6:.0f} MB' for kind, bytes_ in sorted(kinds.items(), key=lambda x: -x[1])[:6]))
    for name, bytes_ in sorted(held.items(), key=lambda x: -x[1])[:5]:
        print(f'  {bytes_ / 1e6:7.0f} MB  {size[name][1]}  {size[name][2].op_type}  {name[-56:]}')


for path in sys.argv[1:]:
    alive(path)
