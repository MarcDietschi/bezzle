# quantize_onnx.py <BiRefNet.onnx or BiRefNet-fp32.onnx> <out.onnx>
# The Windows subject matte with its weights kept to 8 bits, as the Mac's are (Core ML's linear
# quantization, convert.py): every convolution's and matrix product's weights, in steps of their
# own for each output channel, symmetric, each followed by DequantizeLinear, which ONNX Runtime runs
# before the layer (and a Cast back to half precision, given the half-precision model); everything
# else, the attention biases among it, stays as it was. Given the half-precision model, the layers
# still work in half precision; given the full-precision one, in full precision. Either halves the
# half-precision file, for measuring whether the cutouts stay the same (README.md, "For Windows").
# It changes no model code: it only rewrites the ONNX graph.
import sys
from collections import defaultdict
import numpy as np
import onnx
from onnx import helper, numpy_helper, TensorProto

model = onnx.load(sys.argv[1])
graph = model.graph
initializers = {t.name: t for t in graph.initializer}
readers = defaultdict(list)
for node in graph.node:
    for k, name in enumerate(node.input):
        readers[name].append((node, k))


def weights_of(name, seen=()):
    """The layers reading `name` as their weights, through Identity nodes; None if anything else reads it."""
    found = []
    for node, k in readers[name]:
        if node.op_type == 'Identity':
            further = weights_of(node.output[0], seen + (name,))
            if further is None:
                return None
            found += further
        elif node.op_type in ('Conv', 'MatMul') and k == 1:
            found.append(node.op_type)
        else:
            return None
    return found


kept = []
made_nodes = []
before = sum(numpy_helper.to_array(t).nbytes for t in graph.initializer)
for name, tensor in list(initializers.items()):
    if tensor.data_type not in (TensorProto.FLOAT16, TensorProto.FLOAT):
        continue
    half = tensor.data_type == TensorProto.FLOAT16
    w = numpy_helper.to_array(tensor).astype(np.float32)
    if w.ndim < 2 or w.size < 4096:
        continue
    users = weights_of(name)
    if not users or len(set(users)) != 1:
        continue
    # A convolution's output channels are its first axis, a matrix product's its last.
    axis = 0 if users[0] == 'Conv' else w.ndim - 1
    others = tuple(a for a in range(w.ndim) if a != axis)
    scale = np.abs(w).max(axis=others) / 127
    scale[scale == 0] = 1
    shape = [1] * w.ndim
    shape[axis] = -1
    q = np.clip(np.round(w / scale.reshape(shape)), -127, 127).astype(np.int8)
    graph.initializer.remove(tensor)
    graph.initializer.extend([
        numpy_helper.from_array(q, name + '_q8'),
        numpy_helper.from_array(scale.astype(np.float32), name + '_scale'),
        numpy_helper.from_array(np.zeros(scale.shape, np.int8), name + '_zero'),
    ])
    if half:
        made_nodes += [
            helper.make_node('DequantizeLinear', [name + '_q8', name + '_scale', name + '_zero'], [name + '_f32'], axis=axis, name=name + '_dequantize'),
            helper.make_node('Cast', [name + '_f32'], [name], to=TensorProto.FLOAT16, name=name + '_half'),
        ]
    else:
        made_nodes.append(helper.make_node('DequantizeLinear', [name + '_q8', name + '_scale', name + '_zero'], [name], axis=axis,
                                           name=name + '_dequantize'))
    kept.append((name, users[0], w.shape))

# First, before anything reads them.
nodes = list(graph.node)
del graph.node[:]
graph.node.extend(made_nodes + nodes)
after = sum(numpy_helper.to_array(t).nbytes for t in graph.initializer)
print(f'{len(kept)} weights kept to 8 bits ({sum(1 for k in kept if k[1] == "Conv")} convolutions, '
      f'{sum(1 for k in kept if k[1] == "MatMul")} matrix products): {before / 1e6:.0f} MB of weights to {after / 1e6:.0f} MB')
onnx.save(model, sys.argv[2])
onnx.checker.check_model(sys.argv[2])
