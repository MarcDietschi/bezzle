# lighter.py: the same network, asking for far less memory while it runs. Two rearrangements of the
# order things are done in; no weight changes, and the matte is the same but for rounding.
#
# 1. A deformable convolution's taps, one after another (deform.py, in_turn). A 7 × 7 one is 49
#    samplings summed up. A runtime is free to make all 49 before it sums any, and ONNX Runtime
#    does: at 1,024 pixels that is 49 × 67 MB alive at once, at 2,048 pixels 13 GB. Each tap now
#    waits for the sum so far.
# 2. The decoder's last layer, before the enlarging instead of after. BiRefNet enlarges 192
#    channels to the picture's size, puts the 48 made from the picture beside them, and weighs all
#    240 into the one channel of the matte: 1.8 GB alive at 1,024 pixels, 7 GB at 2,048, for a
#    weighted sum. Weighing the 192 first and enlarging the one channel that leaves gives the same,
#    since both steps only add up neighbours and channels.
#
# What is alive at the peak, measured in ONNX Runtime on the processor: 3.6 GB before and 1.0 GB
# after at 1,024 pixels (README.md, "For Windows").
import torch
import deform


class Narrowed(torch.nn.Module):
    """The decoder's last block, then its 192 channels weighed into one, as the last layer would."""
    def __init__(self, block, weigh):
        super().__init__()
        self.block, self.weigh = block, weigh

    def forward(self, x):
        return self.weigh(self.block(x))


class Summed(torch.nn.Module):
    """The last layer for what is left: the channel already weighed, plus the picture's channels weighed."""
    def __init__(self, weigh):
        super().__init__()
        self.weigh = weigh

    def forward(self, x):
        return x[:, :1] + self.weigh(x[:, 1:])


def lighter(model):
    """Rearranges `model` (a BiRefNet with its weights loaded) in place."""
    deform.in_turn = True
    decoder = model.decoder
    last = decoder.conv_out1[0]
    assert last.kernel_size == (1, 1) and last.out_channels == 1, 'the last layer is not the one this was written for'
    # The picture's channels come last in what the last layer reads (Decoder.forward).
    wide = last.in_channels - decoder.ipt_blk1.conv_out.out_channels
    first = torch.nn.Conv2d(wide, 1, 1, bias=False)
    rest = torch.nn.Conv2d(last.in_channels - wide, 1, 1, bias=True)
    with torch.no_grad():
        first.weight.copy_(last.weight[:, :wide])
        rest.weight.copy_(last.weight[:, wide:])
        rest.bias.copy_(last.bias)
    decoder.decoder_block1 = Narrowed(decoder.decoder_block1, first)
    decoder.conv_out1 = Summed(rest)
    return model.eval()
