# half_onnx.py <fp32.onnx> <out.onnx>
# The model in half precision, as the Mac's, but for sampling (GridSample), which half precision
# ruins; the image in and the matte out stay float 32, so the app hands it the same arrays either way.
# ONNX Runtime's converter puts the casts it adds for that at the end of the graph, so the nodes are
# put back in order, each after what it reads, before the model is checked and saved.
import sys
from collections import defaultdict, deque
import onnx
from onnxruntime.transformers.float16 import convert_float_to_float16


def in_order(graph):
    """Sorts the graph's nodes so each comes after the nodes whose outputs it reads (Kahn)."""
    nodes = list(graph.node)
    made_by = {out: k for k, n in enumerate(nodes) for out in n.output if out}
    waits = [0] * len(nodes)
    readers = defaultdict(list)
    for k, n in enumerate(nodes):
        before = {made_by[i] for i in n.input if i in made_by and made_by[i] != k}
        waits[k] = len(before)
        for b in before:
            readers[b].append(k)
    ready = deque(k for k in range(len(nodes)) if waits[k] == 0)
    order = []
    while ready:
        k = ready.popleft()
        order.append(k)
        for r in readers[k]:
            waits[r] -= 1
            if waits[r] == 0:
                ready.append(r)
    if len(order) != len(nodes):
        raise ValueError('the graph goes round in a circle')
    del graph.node[:]
    graph.node.extend(nodes[k] for k in order)


def half(fp32, out):
    model = convert_float_to_float16(onnx.load(fp32), keep_io_types=True, op_block_list=['GridSample'])
    in_order(model.graph)
    onnx.save(model, out)
    onnx.checker.check_model(out)


if __name__ == '__main__':
    half(sys.argv[1], sys.argv[2])
