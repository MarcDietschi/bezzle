# Subject matte

Remove Background's edges come from a learned matte: BiRefNet_HR (Peng Zheng et al., MIT licence),
the high-resolution model trained at 2,048 pixels, converted to Core ML with its weights kept to 8 bits.
`CutoutMaker` keeps it to the subject Vision found. It comes with the app:
`Bezzle/Canvas/BiRefNet.mlpackage`, which Xcode compiles into `BiRefNet.mlmodelc`. That adds about
228 MB to the app. Without it, pictures are cut out the older way, less fine round hair.

The package holds the model at two sizes of picture, 2,048 and 1,024 pixels, as the functions
`side2048` and `side1024`. They share their weights, so the second size costs 3 MB. Which one a Mac
takes, and where it runs, is below (What it asks of a Mac).

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
the script, checking it against the code and weights that were reviewed. It converts the model at
both sizes (`convert.py`), keeps their weights to 8 bits (half the size, measuring the same) and
puts the two into one package (`sizes.py`), at `Bezzle/Canvas/BiRefNet.mlpackage`. It runs BiRefNet's
own model code, so run it yourself.

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
  Bezzle runs it on the GPU or on the processor, by what the Mac has (below).

## What it asks of a Mac

At 2,048 pixels on the GPU, as Bezzle ran it on every Mac up to 1.6, the model holds 20 GB for as
long as it is loaded: more than most Macs have, which took Bezzle down or the Mac to a crawl. So the
model comes at two sizes, runs on the GPU or on the processor, and `SubjectModel` takes the way a
Mac can afford for the picture at hand. Measured on an M5 Pro (18 cores, 48 GB), a picture of
2,400 pixels:

| Way (`SubjectMatte.Route`) | A matte, warm | First in a session | First ever | Memory at its peak | Held after |
|---|---|---|---|---|---|
| 2,048 on the GPU (`gpu2048`) | 0.8 s | 5 s | 36 s | 20.0 GB | 20 GB, until let go |
| 2,048 on the processor (`cpu2048`) | 5.9 s | 7 s | 11 s | 4.3 GB | 0.14 GB |
| 1,024 on the GPU (`gpu1024`) | 0.2 s | 1.1 s | 13 s | 5.0 GB | 5 GB, until let go |
| 1,024 on the processor (`cpu1024`) | 1.5 s | 1.8 s | 8.5 s | 1.1 GB | 0.07 GB |

- **First ever** is the first matte a way makes after Bezzle is installed or updated: Core ML fits
  the model to the Mac's processor or GPU then, and keeps what it made
  (`~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`). It takes many times as long as any
  matte after it, so a way never taken is not taken first: the picture is cut out by a way that is
  ready, or by the quickest to make ready (the light size on the processor, which is made ready
  behind everything else as soon as a picture is selected), and the best way is made ready behind
  it for the next picture (`SubjectModel.isReady`, `order`).
- **Which Mac takes which** (`SubjectModel.routes`; a large picture is one of 1,536 pixels and more,
  as worked on): 36 GB and more take the GPU, at the fine size for a large picture; 24 GB the fine
  size on the processor for a large picture, where there are 8 fast cores, and else the light size
  on the GPU; 16 GB the fine size on the processor for a large picture with 8 fast cores, else the
  light size on the processor; less than 16 GB the light size on the processor, always. An Intel
  Mac takes the light size on the processor from 16 GB and 8 cores (42 to 47 s under Rosetta here),
  and below that cuts out without the model.
- **How the two sizes compare:** on the portraits their edges measure nearly alike (the table
  above: 5.08 against 6.00 in alpha); on pictures smaller than the fine size the light one is the
  better, as it does not blow them up (the bowl of raspberries, 1,080 pixels, keeps its whole bowl
  at 1,024 and loses a part of it at 2,048 in half precision). Cutouts are named for the size they
  were made at (`cutoutName`: `-cutout-m1` fine, `-cutout-m1-1024` light), and a finer one made on
  another Mac is taken as it is.
- **Nothing is trusted blindly:** a way that fails is followed by the next lighter one, and the
  last by the older way without the model; a way that was running when Bezzle went down is passed
  over by that version of Bezzle from then on (`subjectMatte.running`, `subjectMatte.avoided` in
  the app's settings); a way that took more than 25 s is passed over for a lighter one; the GPU is
  left alone while macOS says memory is short. The model is let go 45 s after its last picture on
  the GPU (5 minutes on the processor) and at once when memory runs short, which frees the GPU's
  memory within a second.
- **Trying a way:** `BEZZLE_MATTE_ROUTE=cpu1024` (or `gpu1024`, `cpu2048`, `gpu2048`) takes that
  way alone; `BEZZLE_MATTE_MACHINE=8:4:arm` takes the ways of a Mac with 8 GB and 4 fast cores
  (`intel` for an Intel Mac) on this one, which shows what such a Mac does but not how long it
  takes there.

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
matte is the Mac's: `build/onnx/BiRefNet-fp32.onnx`, checked against PyTorch with ONNX Runtime; from
it `build/onnx/BiRefNet.onnx`, which Windows ships, its weights kept to 8 bits as the Mac's are and its
layers in full precision (`quantize_onnx.py`; why, below); and `BiRefNet-fp16.onnx`, half precision,
for comparison. All are ignored by git. It runs BiRefNet's own model code, so run it yourself.
`Windows/VM/send-matte.sh` brings the shipped one to a Windows build machine (`Windows/README.md`),
and `Windows/onnx.ps1` pins its checksum.

Windows runs it with ONNX Runtime 1.24.4: on the graphics card through DirectML, else on the
processor. Half precision was shipped first and lost whole regions where it was computed in half
precision (Arm processors, below); the 8-bit model computes in full precision everywhere, keeps every
photo measured, and is 275 MB rather than 471. Its speed on graphics cards, where full precision is
slower than half, is not measured yet (the VM has no Direct3D 12 adapter).

### Measured on Windows (2026-11-08)

Against the full-precision model on the very input Windows gave the model (10 photos: the sample
designs' and two made of the pug), the share of alpha that differs on average and on the edge (%),
the share plainly wrong (off by more than half, %), and the overlap of what is at least half solid:

| | Mean | Edge | Gross | IoU | File | Compressed |
|---|---|---|---|---|---|---|
| Half precision, on the VM's Arm processor (first shipped) | 1.52 | 13.0 | 1.46 | 96.9 | 471 MB | 395 MB |
| Half precision, on the Mac's processor (8 photos, Pillow's squeeze) | 0.05 | 0.72 | 0 | 99.9 | | |
| 8 bits, half-precision layers (`quantize_onnx.py BiRefNet.onnx`) | 0.05 | 1.05 | 0 | 99.85 | 252 MB | 199 MB |
| 8 bits, full-precision layers (`quantize_onnx.py BiRefNet-fp32.onnx`, shipped) | 0.05 | 0.75 | 0 | 99.89 | 275 MB | 200 MB |
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
