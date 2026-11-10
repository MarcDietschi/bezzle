# share_onnx.py <out dir> <weights file name> <name.onnx>=<model.onnx> [<name.onnx>=<model.onnx> …]
# Puts several ONNX models of the same network (the Windows subject matte at its sizes of picture)
# beside one file of weights that all of them read: each model keeps its graph, and every weight of
# 1 KB and more goes into the weights file once, however many models and layers hold it (found by
# what it holds, not by its name). ONNX calls this external data; ONNX Runtime reads the file from
# beside the model. The 8-bit model is 275 MB, and a second size of it costs 5 MB this way.
# It changes no model code and no number: it only moves where the weights are kept.
import sys, os, hashlib
import onnx
from onnx import TensorProto

out, weights = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
at = {}        # what a weight holds → where it is in the file
length = 0
with open(os.path.join(out, weights), 'wb') as file:
    for given in sys.argv[3:]:
        name, path = given.split('=', 1)
        model = onnx.load(path)
        moved = 0
        for tensor in model.graph.initializer:
            # Only weights kept as raw bytes; the small ones stay in the graph.
            if tensor.data_location == TensorProto.EXTERNAL or not tensor.HasField('raw_data') or len(tensor.raw_data) < 1024:
                continue
            data = tensor.raw_data
            key = (hashlib.sha256(data).digest(), tensor.data_type, tuple(tensor.dims))
            if key not in at:
                # Each begins on a 64-byte line, so a reader mapping the file finds it aligned.
                pad = -length % 64
                file.write(b'\0' * pad)
                at[key] = length + pad
                file.write(data)
                length += pad + len(data)
            tensor.ClearField('raw_data')
            tensor.data_location = TensorProto.EXTERNAL
            del tensor.external_data[:]
            for k, v in (('location', weights), ('offset', at[key]), ('length', len(data))):
                entry = tensor.external_data.add()
                entry.key, entry.value = k, str(v)
            moved += 1
        with open(os.path.join(out, name), 'wb') as graph:
            graph.write(model.SerializeToString())
        onnx.checker.check_model(os.path.join(out, name))
        print(f'{name}: {moved} weights in {weights}, {os.path.getsize(os.path.join(out, name)) / 1e6:.1f} MB of its own')
print(f'{weights}: {len(at)} weights, {length / 1e6:.0f} MB')
