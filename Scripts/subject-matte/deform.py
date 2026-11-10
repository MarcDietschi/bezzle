# deform.py: torchvision's modulated deformable convolution (stride 1, dilation 1, one offset group)
# written with grid_sample, which Core ML has, so a model using it can be converted.
import torch
import torch.nn.functional as F

# Each tap waits for the sum of those before it, so no runtime makes all of them before summing any
# (lighter.py says what that costs). It adds nothing: a number of the sum so far, times zero.
in_turn = False


def deform_conv2d(input, offset, weight, bias=None, padding=0, mask=None, stride=1):
    s = stride if isinstance(stride, tuple) else (stride, stride)
    pad = padding if isinstance(padding, tuple) else (padding, padding)
    assert s == (1, 1)
    # Sizes as plain numbers, so a traced model has them fixed.
    h, w = int(input.shape[2]), int(input.shape[3])
    kh, kw = int(weight.shape[2]), int(weight.shape[3])
    oh, ow = int(offset.shape[2]), int(offset.shape[3])
    sy, sx = 2.0 / max(h - 1, 1), 2.0 / max(w - 1, 1)
    ys = (torch.arange(oh, dtype=input.dtype, device=input.device).view(1, oh, 1) - float(pad[0])) * sy - 1.0
    xs = (torch.arange(ow, dtype=input.dtype, device=input.device).view(1, 1, ow) - float(pad[1])) * sx - 1.0
    out = None
    for i in range(kh):
        for j in range(kw):
            k = i * kw + j
            # align_corners: -1 and 1 are the middles of the first and last pixels.
            gy = ys + (float(i) + offset[:, 2 * k]) * sy
            if in_turn and out is not None:
                gy = gy + out[:, 0, :1, :1] * 0
            gx = xs + (float(j) + offset[:, 2 * k + 1]) * sx
            grid = torch.stack((gx, gy), dim=-1)
            sampled = F.grid_sample(input, grid, mode='bilinear', padding_mode='zeros', align_corners=True)
            if mask is not None:
                sampled = sampled * mask[:, k:k + 1]
            term = F.conv2d(sampled, weight[:, :, i:i + 1, j:j + 1])
            out = term if out is None else out + term
    if bias is not None:
        out = out + bias.view(1, -1, 1, 1)
    return out


if __name__ == '__main__':
    import torchvision.ops
    torch.manual_seed(0)
    for (c, o, k, h, w) in [(64, 256, 1, 32, 40), (64, 256, 3, 32, 40), (64, 256, 7, 33, 29)]:
        x = torch.randn(1, c, h, w)
        off = torch.randn(1, 2 * k * k, h, w) * 3
        m = torch.sigmoid(torch.randn(1, k * k, h, w)) * 2
        wt = torch.randn(o, c, k, k) * 0.05
        ref = torchvision.ops.deform_conv2d(x, off, wt, None, padding=k // 2, mask=m)
        got = deform_conv2d(x, off, wt, None, padding=k // 2, mask=m)
        print(k, 'max diff', (ref - got).abs().max().item(), 'scale', ref.abs().max().item())
