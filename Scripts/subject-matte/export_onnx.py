# export_onnx.py <code dir> <weights dir> <side> <out dir> [check photo]
# Exports BiRefNet (its model code in <code dir>/brn, its weights from safetensors) to ONNX for Bezzle
# for Windows, which runs it with ONNX Runtime: 0…1 RGB in, side × side, the matte of what stands out,
# 0…1, out. As convert.py does for Core ML: deformable convolution done with grid_sample, and Swin's
# attention mask made in the model from small labels. Writes BiRefNet-fp32.onnx, checks it against
# PyTorch, then BiRefNet.onnx: half precision throughout but for sampling, as the Mac's model. See README.md.
import sys, os, importlib, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
code, weights, side, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
check = sys.argv[5] if len(sys.argv) > 5 else None
sys.path.insert(0, os.path.abspath(code))
import numpy as np
import torch
import onnx
import onnxruntime as ort
from PIL import Image
from safetensors.torch import load_file
import deform
from half_onnx import half

mod = importlib.import_module('brn.birefnet')
cfg = importlib.import_module('brn.BiRefNet_config')
model = mod.BiRefNet(config=cfg.BiRefNetConfig(bb_pretrained=False))
model.load_state_dict({k: v.float() for k, v in load_file(os.path.join(weights, 'model.safetensors')).items()})
model.eval()


class Wrapped(torch.nn.Module):
    """0…1 RGB in; the matte out."""
    def __init__(self, m):
        super().__init__()
        self.m = m
        self.register_buffer('mean', torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, x):
        return self.m((x - self.mean) / self.std)[-1].sigmoid()


wrapped = Wrapped(model).eval()
photo = Image.open(check).convert('RGB').resize((side, side), Image.BILINEAR) if check else None
x = torch.from_numpy(np.asarray(photo, dtype=np.float32) / 255).permute(2, 0, 1).unsqueeze(0) if photo else torch.rand(1, 3, side, side)
with torch.no_grad():
    reference = wrapped(x).numpy()

# The same two changes convert.py makes, so the Windows matte is the Mac's.
mod.deform_conv2d = deform.deform_conv2d


def labels(window, shift, H, W):
    Hp, Wp = -(-H // window) * window, -(-W // window) * window
    img = np.zeros((1, Hp, Wp, 1), np.float32)
    cnt = 0
    for hs in (slice(0, -window), slice(-window, -shift), slice(-shift, None)):
        for ws in (slice(0, -window), slice(-window, -shift), slice(-shift, None)):
            img[:, hs, ws, :] = cnt
            cnt += 1
    m = img.reshape(1, Hp // window, window, Wp // window, window, 1).transpose(0, 1, 3, 2, 4, 5).reshape(-1, window * window)
    return torch.from_numpy(m)


def layer_forward(self, x, H, W):
    H, W = int(H), int(W)
    # Tied to the input, so the exporter cannot fold the mask (windows × window² × window²) into a
    # constant of a hundred megabytes and more.
    m = labels(self.window_size, self.shift_size, H, W).to(x.dtype) + x.reshape(-1)[0] * 0
    attn_mask = (m.unsqueeze(1) != m.unsqueeze(2)).to(x.dtype) * -100.0
    for blk in self.blocks:
        blk.H, blk.W = H, W
        x = blk(x, attn_mask)
    if self.downsample is not None:
        x_down = self.downsample(x, H, W)
        Wh, Ww = (H + 1) // 2, (W + 1) // 2
        return x, H, W, x_down, Wh, Ww
    return x, H, W, x, H, W


mod.BasicLayer.forward = layer_forward

with torch.no_grad():
    patched = wrapped(x).numpy()
print('patched against original: max', np.abs(patched - reference).max(), 'mean', np.abs(patched - reference).mean())

os.makedirs(out, exist_ok=True)
fp32 = os.path.join(out, 'BiRefNet-fp32.onnx')
fp16 = os.path.join(out, 'BiRefNet.onnx')

t0 = time.time()
with torch.no_grad():
    torch.onnx.export(wrapped, (x,), fp32, input_names=['image'], output_names=['matte'],
                      opset_version=17, do_constant_folding=True, dynamo=False)
print('exported', round(time.time() - t0), 's')
onnx.checker.check_model(fp32)

t0 = time.time()
got = ort.InferenceSession(fp32, providers=['CPUExecutionProvider']).run(['matte'], {'image': x.numpy()})[0]
print('onnx runtime (fp32) against pytorch: max', np.abs(got - reference).max(), 'mean', np.abs(got - reference).mean(),
      'in', round(time.time() - t0), 's')

# Half precision, as the Mac's model, but for sampling (half_onnx.py).
half(fp32, fp16)
for path in (fp32, fp16):
    print(os.path.basename(path), round(os.path.getsize(path) / 1e6), 'MB')
print('The half-precision model is checked on Windows, with DirectML: ONNX Runtime has no half-precision kernels on a CPU.')
