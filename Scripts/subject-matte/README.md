# Subject matte

Remove Background's edges come from a learned matte: BiRefNet_HR (Peng Zheng et al., MIT licence),
the high-resolution model trained at 2,048 pixels, converted to Core ML with its weights kept to 8 bits.
`CutoutMaker` keeps it to the subject Vision found. It comes with the app:
`Bezzle/Canvas/BiRefNet.mlpackage`, which Xcode compiles into `BiRefNet.mlmodelc`. That adds about
225 MB to the app. Without it, pictures are cut out the older way, less fine round hair.

The model is too large for git (GitHub refuses files over 100 MB), so it is ignored. Make it on
each Mac that builds Bezzle, once, with `make.sh`. `CutoutTests.theAppComesWithTheLearnedMatte…`
fails when it is missing.

## Why this model

These were measured on 11 portraits whose true edges were known: cutouts put back onto backgrounds,
with every subject kept. Errors are on the true edge, in alpha (%) and colour (0 to 255), plus the
share of the subject that is plainly wrong (alpha off by more than half).

| | Edge alpha | Edge colour | Gross |
|---|---|---|---|
| Vision and the guided filter (before) | 8.65 | 13.6 | 5.1 |
| BiRefNet_HR, 8-bit, in Bezzle | **5.08** | **7.6** | **0.6** |
| BiRefNet (1024) | 6.00 | 8.1 | 0.8 |
| BiRefNet_HR-matting | 6.20 | 9.5 | 1.5 |
| BiRefNet_lite | 9.12 | 13.0 | 3.1 |

The matting variants are best on hair alone but keep bystanders. The lite variants leave smears.

## Making it

```
Scripts/subject-matte/make.sh [a photo to check it on]
```

The script makes a Python 3.13 environment in `build/` and downloads the model at the revision in
the script, checking it against the code and weights that were reviewed. It converts the model,
keeps its weights to 8 bits (half the size, measuring the same), and puts it at
`Bezzle/Canvas/BiRefNet.mlpackage`. It runs BiRefNet's own model code, so run it yourself.

Raise `SubjectMatte.version` when the model changes. Cutouts are named for the version
(`cutoutName`), so pictures are cut out afresh rather than reusing the old model's cutouts.

What the conversion has to get right (`convert.py`):
- Core ML has no deformable convolution. `deform.py` does the same with `grid_sample`, matching
  torchvision to float precision.
- Core ML's half-precision `resample` (grid_sample) is wrong: its error is larger than the signal.
  It is kept in full precision; everything else is half.
- Swin's attention masks are made in the model from small labels, tied to the input so the converter
  cannot work them out ahead; kept as constants they were 50 MB more.
- On the Neural Engine this model is wrong and slow (two minutes to load, ten seconds a picture).
  Bezzle runs it on CPU and GPU: about 0.8 s a picture once warm.

## Trying another

`BEZZLE_MATTE_MODEL` takes another model, a compiled `.mlmodelc` or an `.mlpackage`, in place of the
app's own: `open -n --env BEZZLE_LIBRARY=<scratch> --env BEZZLE_MATTE_MODEL=<path> Bezzle.app`.
Tests run without the learned matte unless given one this way.

The licence notices are in `LICENSE-BiRefNet.txt` and in the app's About window (`Credits.rtf`).

## For Windows

```
Scripts/subject-matte/make-onnx.sh [a photo to check it on]
```

Bezzle for Windows runs the same model with ONNX Runtime. After `make.sh` has made the environment
and fetched the model, this exports it to ONNX at 2,048 pixels with the two changes `convert.py`
makes (deformable convolution with grid_sample, Swin's mask made in the model), so the Windows
matte is the Mac's: `build/onnx/BiRefNet-fp32.onnx`, checked against PyTorch with ONNX Runtime, and
`build/onnx/BiRefNet.onnx`, half precision but for sampling, as the Mac's, which Windows uses. Both
are ignored by git. It runs BiRefNet's own model code, so run it yourself. `Windows/VM/send-matte.sh`
brings the half-precision one to a Windows build machine (`Windows/README.md`).

Windows runs it with ONNX Runtime 1.24.4: on the graphics card through DirectML, else on the
processor, where ONNX Runtime runs the half-precision nodes it has no half-precision kernels for in
full precision. Arm processors have many such kernels, and they lose precision (below); x64 ones
have few, it is thought, which was not measured here.

### Measured on Windows (2026-11-08)

Against the full-precision model on the very input Windows gave the model (10 photos: the sample
designs' and two made of the pug), the share of alpha that differs on average and on the edge (%),
the share plainly wrong (off by more than half, %), and the overlap of what is at least half solid:

| | Mean | Edge | Gross | IoU | File | Compressed |
|---|---|---|---|---|---|---|
| Half precision, on the VM's Arm processor (shipped) | 1.52 | 13.0 | 1.46 | 96.9 | 471 MB | 395 MB |
| Half precision, on the Mac's processor (8 photos, Pillow's squeeze) | 0.05 | 0.72 | 0 | 99.9 | | |
| 8 bits, half-precision layers (`quantize_onnx.py BiRefNet.onnx`) | 0.05 | 1.05 | 0 | 99.85 | 252 MB | 199 MB |
| 8 bits, full-precision layers (`quantize_onnx.py BiRefNet-fp32.onnx`) | 0.05 | 0.75 | 0 | 99.89 | 275 MB | 200 MB |
| The Mac's own Core ML model on its GPU, for comparison (8 photos) | 0.88 | 11.1 | 0.65 | 97.8 | 225 MB | |

The rows run on the Mac's processor compute in full precision whatever the file keeps (ONNX Runtime
has no half-precision kernels there), so they show what the weights alone do: 8 bits changes the
matte about as little as half precision does. Computing in half precision is what costs: on the VM's
Arm processor the bowl of raspberries and the bell beside the latte lose whole parts (11% and 3% of
the picture plainly wrong), as the Mac's GPU loses parts of the same two. There, 8 bits with
half-precision layers loses the same (10.7% and 3.4%), and 8 bits with full-precision layers none
(0.25% and 0.09% on average, nothing plainly wrong), in the same time and memory: 63 to 72 s a
picture and 10 to 10.7 GB at the peak for each of the three (the Mac's processor: 25 s, 14 GB).
DirectML is not measured, as the VM has no graphics card and Windows' software adapter runs out of
memory at 2,048 pixels; on a graphics card full precision should take longer than half, and twice
the memory between layers. `compare_mattes.py` compares mattes that
`bezzle-render <fonts> cutout <out>` writes with `BEZZLE_MATTE_RAW`, for checking a graphics card
the same way.
