# Subject matte

Remove Background's edges come from a learned matte: BiRefNet_HR (Peng Zheng et al., MIT licence),
the high-resolution model trained at 2,048 pixels, converted to Core ML with its weights kept to 8 bits.
`CutoutMaker` keeps it to the subject Vision found. It comes with the app:
`Bezzle/Canvas/BiRefNet.mlpackage`, which Xcode compiles into `BiRefNet.mlmodelc`. That adds about
229 MB to the app. Without it, pictures are cut out the older way, less fine round hair.

The package holds the model at two sizes of picture, 2,048 and 1,024 pixels, as the functions
`side2048` and `side1024`. They share their weights, so the second size costs 4 MB. Which one a Mac
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
- As BiRefNet is written, it asks for far more memory than it needs (`lighter.py`). A deformable
  convolution of 7 × 7 is 49 samplings summed up, and a runtime is free to make all 49 before it
  sums any: each tap now waits for the sum so far. And the decoder's last layer weighs 240
  channels at the picture's full size into the one channel of the matte, 192 of them enlarged
  just before: they are now weighed first and the one channel enlarged, which gives the same. No
  weight changes, and the matte is the same but for rounding (on 5 photos, at both sizes, the
  alpha differs by less than 0.1% on the edge). On the GPU the fine size holds 9 GB where it held
  20, and its first matte ever takes 19 s where it took 36.

## What it asks of a Mac

At 2,048 pixels on the GPU, as Bezzle ran it on every Mac up to 1.6, the model held 20 GB for as
long as it was loaded: more than most Macs have, which took Bezzle down or the Mac to a crawl. Two
things changed. The network is rearranged to keep far less alive at once (`lighter.py`, above),
and it comes at two sizes, runs on the GPU or on the processor, and `SubjectModel` takes the way a
Mac can afford for the picture at hand. Measured on an M5 Pro (18 cores, 48 GB), a picture of
2,400 pixels:

| Way (`SubjectMatte.Route`) | A matte, warm | First in a session | First ever | Memory at its peak | Held after |
|---|---|---|---|---|---|
| 2,048 on the GPU (`gpu2048`) | 0.8 s | 3.5 s | 19 s | 9.3 GB | 9 GB, until let go |
| 2,048 on the processor (`cpu2048`) | 5.7 s | 5.8 s | 12 s | 1.9 GB | 0.1 GB |
| 1,024 on the GPU (`gpu1024`) | 0.2 s | 2.6 s | 20 s | 2.8 GB | 2.5 GB, until let go |
| 1,024 on the processor (`cpu1024`) | 1.5 s | 1.5 s | 8.5 s | 0.6 GB | 0.1 GB |

Before the rearrangement the four peaked at 20.0, 4.3, 5.0 and 1.1 GB, and the fine size's first
matte ever on the GPU took 36 s.

- **First ever** is the first matte a way makes after Bezzle is installed or updated: Core ML fits
  the model to the Mac's processor or GPU then (6 to 7 s), for the GPU its programs are built too
  (11 s, once for both sizes), and both are kept (`~/Library/Caches/<bundle id>/
  com.apple.e5rt.e5bundlecache`, and Metal's own cache). To measure it, run from a bundle id never
  used before: clearing the first cache alone leaves the GPU's programs. It takes many times as
  long as any matte after it, so a way never taken is not taken first: the picture is cut out by a
  way that is ready, or by the quickest to make ready (the light size on the processor, which is
  made ready behind everything else as soon as a picture is selected), and the best way is made
  ready behind it for the next picture (`SubjectModel.isReady`, `order`).
- **Which Mac takes which** (`SubjectModel.routes`; a large picture is one of 1,536 pixels and more,
  as worked on): 24 GB and more take the fine size on the GPU for a large picture, and after it the
  fine size on the processor where there are 8 fast cores; 16 GB and more take the light size on
  the GPU, as the larger Macs do for a smaller picture; less than 16 GB the light size on the
  processor, always. So no way holds more than two fifths of a Mac's memory. An Intel Mac takes
  the light size on the processor from 16 GB and 8 cores (42 to 47 s under Rosetta here), and
  below that cuts out without the model. None of this is measured on a Mac of 8 or 16 GB: what
  such a Mac does can be tried here (`BEZZLE_MATTE_MACHINE`, below), how long it takes there cannot.
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
and fetched the model, this exports it to ONNX at the Mac's two sizes, 2,048 and 1,024 pixels, with
the changes `convert.py` makes (deformable convolution with grid_sample, Swin's mask made in the
model, the rearrangement of `lighter.py`), so the Windows matte is the Mac's. Each export is
checked against PyTorch with ONNX Runtime (`build/onnx/<size>/BiRefNet-fp32.onnx`) and its weights
are kept to 8 bits as the Mac's are, its layers in full precision (`quantize_onnx.py`; why, below).
The two sizes have every weight in common, so the weights are stored once and each graph reads
them from the file beside it (`share_onnx.py`; ONNX calls it external data). What Windows ships,
in `build/onnx`:

| | | |
|---|---|---|
| `BiRefNet-2048.onnx` | the fine size's graph | 8 MB |
| `BiRefNet-1024.onnx` | the light size's graph | 6 MB |
| `BiRefNet.weights` | the weights both read | 269 MB |

The three are of one making and go together. A half-precision export of the fine size
(`build/onnx/2048/BiRefNet-fp16.onnx`) is made for comparison. All are ignored by git. It runs
BiRefNet's own model code, so run it yourself. `Windows/VM/send-matte.sh` brings the three to a
Windows build machine (`Windows/README.md`), and `Windows/onnx.ps1` pins their checksums.

Windows runs it with ONNX Runtime 1.24.4: on the graphics card through DirectML, or on the
processor. Half precision was shipped first and lost whole regions where it was computed in half
precision (Arm processors, below); the 8-bit model computes in full precision everywhere and keeps
every photo measured. Its speed on graphics cards, where full precision is slower than half, is not
measured yet (the VM has no Direct3D 12 adapter).

### What it asks of a PC

Up to Bezzle 1.6, Windows ran the fine size alone, as BiRefNet is written: through DirectML on any
graphics adapter, integrated ones too, and else on the processor. That took small PCs down, and
the reason is in the graph (`lighter.py`): ONNX Runtime makes all 49 samplings of a 7 × 7
deformable convolution before it sums any. `alive_onnx.py <model.onnx>` runs a model with ONNX
Runtime's own record of every layer and adds up what is alive after each, which is the memory the
model needs whatever the allocator. On this Mac's processor (18 cores, ONNX Runtime 1.22):

| | Alive at its peak | A matte |
|---|---|---|
| 2,048, as shipped up to 1.6 (`BiRefNet.onnx`) | 14.6 GB | 21 s |
| 2,048, rearranged (`BiRefNet-2048.onnx`) | 4.0 GB | 20 s |
| 1,024, not rearranged | 3.6 GB | 5.6 s |
| 1,024, rearranged (`BiRefNet-1024.onnx`) | 1.0 GB | 4.9 s |

So the 10 GB the VM showed at 2,048 pixels (below) was the limit of its 12 GB, not what the model
needed, and its 63 to 72 s were partly paging. What is left at the peak is Swin's first stage (its
attention over every window at once), which is the model's own.

The rearranged graphs give the matte the shipped one gave: on three photos, at 2,048 pixels
against the graph shipped up to 1.6 and at 1,024 against the same export not rearranged, no value
of the matte differs by more than 0.0000013, which is rounding in the last step. So what was
measured on Windows (below) holds for them.

Which PC takes which way is the Mac's question with a PC's answers (`MatteWays.routes`, in
`Windows/Sources/BezzleCore/Host/MatteWays.swift`; a large picture is one of 1,536 pixels and more,
as on the Mac). What decides is the memory a graphics card has of its own, since integrated
graphics share the PC's memory and were what took small PCs down:

- **A card with 12 GB of its own:** the fine size on the card for a large picture, then the light
  size on the card.
- **A card with 6 GB of its own:** the light size on the card.
- **Integrated graphics, smaller cards, Windows' own adapter on the processor, and any PC with
  less than 8 GB of memory:** the card is left alone. The processor makes the matte, at the fine
  size only for a large picture on a PC with 32 GB and 12 fast cores, at the light size on all
  the others.
- **Last on every PC:** the light size on the processor (`cpu1024`), 1 GB while it runs. It is
  never passed over, as Windows has no way without the model.

Each measure sits a little under the round number (11.5, 5.5, 7.5 and 30.5 GB), as Windows counts
less memory than a PC is sold with. All of them are estimates until measured on real PCs.

The safeguards are the Mac's (`MatteLedger` beside the ways, `SubjectModel` in
`Host/SubjectMatte.swift`): a
way that fails is followed by the next lighter one; a way that was running when Bezzle went down
is passed over by that version of Bezzle from then on (`subjectMatte.running`,
`subjectMatte.avoided` in the settings); a way that took more than 25 s is passed over; the card
is left alone while memory is short (nine tenths in use, or less than 1.5 GB left to hand out),
which Bezzle asks every 5 s while a model is loaded, as Windows tells no one. The model is let go
45 s after its last picture on the card. On the processor it is let go after each matte, as ONNX
Runtime kept hold there of what a matte took, so each matte there loads the model first. The last
three pictures' mattes are kept, so picking other subjects asks the model nothing.

**Trying a way:** `BEZZLE_MATTE_ROUTE=cpu1024` (or `gpu1024`, `cpu2048`, `gpu2048`) takes that way
alone; `BEZZLE_MATTE_MACHINE=16:8` takes the ways of a PC with 16 GB and 8 fast cores, and
`32:12:8` those of one with a card of 8 GB besides; `BEZZLE_MATTE_DEVICE=cpu` keeps to the
processor, `gpu` goes through DirectML on any adapter, Windows' software one too;
`BEZZLE_MATTE_MODEL` takes other graphs, a folder of them with their weights or one graph that
every way then runs. The ways, what is remembered of them and the cutouts' names are tested on a
Mac too: `swift test --package-path Windows/Tests`.

**Not measured:** none of this has run on Windows yet. The figures above are ONNX Runtime's on a
Mac's processor; DirectML has never run this model on a real graphics card, at either size; and how
long the light size takes on a PC's processor is a guess from the cores it has. The first build in
the VM should measure the light size there (time and peak memory, `bezzle-render … cutout`).

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
