# convert.py <code dir> <weights dir> <side> <out.mlpackage> [check photo]
# Converts BiRefNet (its model code in <code dir>/brn, its weights from safetensors) to Core ML: an RGB
# image side × side in, the matte of what stands out, 0…1, out. Then, given a photo, checks the Core
# ML model against PyTorch on it. See README.md.
import sys, os, importlib, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
code, weights, side, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
check = sys.argv[5] if len(sys.argv) > 5 else None
sys.path.insert(0, os.path.abspath(code))
import numpy as np
import torch
import coremltools as ct
from PIL import Image
from safetensors.torch import load_file
import deform

mod = importlib.import_module('brn.birefnet')
cfg = importlib.import_module('brn.BiRefNet_config')
model = mod.BiRefNet(config=cfg.BiRefNetConfig(bb_pretrained=False))
model.load_state_dict({k: v.float() for k, v in load_file(os.path.join(weights, 'model.safetensors')).items()})
model.eval()


class Wrapped(torch.nn.Module):
    """0…1 RGB in, as Core ML gives an image scaled by 1/255; the matte out."""
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


# Core ML has no deformable convolution: the same done with grid_sample.
mod.deform_conv2d = deform.deform_conv2d


# Swin's attention mask depends only on the size, which is fixed here. Only each window's region
# labels are kept as a constant (small); the mask, windows × window² × window², is made from them
# in the model, so at 2048 it doesn't add a hundred megabytes of constants.
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
    # Tied to the input, though it never changes with it, so the converter cannot work the mask out
    # ahead and keep it.
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

t0 = time.time()
with torch.no_grad():
    traced = torch.jit.trace(wrapped, x, check_trace=False)
print('traced', round(time.time() - t0), 's')

t0 = time.time()
ml = ct.convert(
    traced,
    inputs=[ct.ImageType(name='image', shape=(1, 3, side, side), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name='matte')],
    minimum_deployment_target=ct.target.macOS15,
    # Half precision throughout, but for sampling, which half precision ruins.
    compute_precision=ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type != 'resample'),
)
ml.short_description = 'BiRefNet_HR (Peng Zheng et al., MIT licence): the matte of what stands out, 0…1.'
ml.save(out)
print('converted', round(time.time() - t0), 's')

if photo:
    # On CPU and GPU, as Bezzle runs it: the Neural Engine gets this model wrong, and slowly.
    got = ct.models.MLModel(out, compute_units=ct.ComputeUnit.CPU_AND_GPU).predict({'image': photo})['matte']
    print('core ml against pytorch: max', np.abs(got - reference).max(), 'mean', np.abs(got - reference).mean())
