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

A process holds more than is alive by this count, though, and how much more is ONNX Runtime's
doing, not the model's. On the processor it plans ahead to give a layer's memory, once the layer
is done with, to a later layer whose result is the same size, and holds it until then (its
`enable_mem_reuse`, which only its Python API can switch off). With this model that more than
doubles what is held. Its parallel mode plans without, and as the whole graph runs on the
processor, it runs the same layers in the same order one at a time: on this Mac ONNX Runtime's own
record shows all 9,388 layers in the same order, none begun before the one before had ended, and
the matte the same bit for bit. So Bezzle runs the processor's sessions in that mode
(`CBezzleHost/matte.cpp`, with two threads between layers, as with one ONNX Runtime goes back to
its plan), in one of two ways:

- **The quick way** keeps what a layer lets go in ONNX Runtime's arena for the layers after it.
- **The lean way** does without the arena: each layer's memory is asked of Windows and given
  back, so no more is held than is alive, and a matte takes two to three times as long.

Measured in the test VM (Windows 11 for Arm, 8 cores, 12 GB, no graphics card; 2026-11-14) with
the model alone: a small program that runs one photo's matte through ONNX Runtime 1.24.4 as
`matte.cpp` does, each run a process of its own, and what Windows counted for the process at its
peak, in memory (its working set) and asked for (committed). Other builds ran in the VM
meanwhile, so the times are longer than a quiet PC's and compare only with one another:

| | A matte | In memory at its peak | Asked of Windows |
|---|---|---|---|
| 1,024, as shipped in 1.7 (no arena, ONNX Runtime's plan) | 21 to 24 s | 2.6 GB | 2.6 GB |
| 1,024, the quick way | 16 to 21 s | 1.7 GB | 2.2 GB |
| 1,024, the lean way | 47 to 50 s | 1.2 GB | 1.1 GB |
| 2,048, as shipped in 1.7 | 156 s | 7.7 GB | 10.0 GB |
| 2,048, the quick way | 95 s | 6.9 GB | 7.7 GB |
| 2,048, the lean way | 190 s | 3.9 GB | 3.9 GB |

At each size the three mattes are the same bit for bit (every one of the 1,048,576 and 4,194,304
values). The fine size as shipped in 1.7 asked for 10 GB, which the VM's 12 GB could not all keep
in memory: part of its time was paging. With the arena and ONNX Runtime's plan together, the light
size held 3.2 GB. Tried and left out: an arena that grows by what is asked or in small steps holds
more, not less (2.1 to 2.3 GB at 1,024 pixels); ONNX Runtime without constant folding holds 1.0 GB
at 1,024 but changes the matte by 0.000003 and loads in 30 s; without memory patterns or
prepacking nothing changes.

The measures that stood here before (2026-11-10: 1.9 GB at either size) were wrong. The script
that read the process's peak kept it in a 32-bit number, which took no value over 2 GB and so
kept the last one under it. `bezzle-render` now says the peak itself after each matte.

A whole cut there, `bezzle-render <fonts> cutout <out>` with a photo of 2,400 pixels at the light
size, the tool at its peak: 2.7 GB in memory as shipped in 1.7, 1.74 GB the quick way (2.30 GB
asked of Windows) and 1.27 GB the lean way (1.14 GB asked). The matte took 18 to 47 s the quick
way, by how much else ran in the VM, and 47 to 56 s the lean way (one after the other: 17.7 s and
55.9 s); on 2026-11-10, alone in the VM, the light size took 10 to 11 s and the fine size 43 to
54 s. Six photos' mattes and cutouts are byte for byte those of the build shipped as 1.7, and
the lean way's matte and cutout of a seventh are the quick way's. At the fine size
(`BEZZLE_MATTE_ROUTE=cpu2048`) the tool held 6.97 GB (7.69 GB asked), the matte took 75 s, and it
is byte for byte the matte made as shipped in 1.7.
`BEZZLE_MATTE_LEFT=1.5` there takes the lean way by itself, and as a PC of 16 GB and 16 cores
with 5 GB left (`BEZZLE_MATTE_MACHINE=16:16`, `BEZZLE_MATTE_LEFT=5`) a large photo takes the light
size, not the fine one. Should ONNX Runtime be raised (`Windows/onnx.ps1`), measure again: that
its parallel mode plans without handing memory on, and runs one layer at a time, is how 1.24.4
is made, not a promise.

So the fine size asks both memory and time of a processor: 7 GB, and four times the light size's
time. Tried in the VM on 2026-11-10: a card that cannot (`BEZZLE_MATTE_MACHINE=16:8:8` on the VM,
which has none) is followed by the processor in the same cut; the fine size on the processor,
having taken 47 s, is passed over the next time; and the tool stopped by force in the middle of a
fine matte says so when it next runs and takes the light size.

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
  size only for a large picture on a PC with 16 fast cores (and 16 GB), where it should take
  about 25 s, at the light size on all the others.
- **Last on every PC:** the light size on the processor (`cpu1024`), 1.7 GB while it runs. It is
  never passed over, as Windows has no way without the model.

And no way on the processor is taken without the memory for it (`MatteWays.fit`): before each
matte Bezzle asks Windows what it has left to hand out, and a way needs what it holds and half a
gigabyte beside for the rest of the cut. The fine size, with less than 7.5 GB left, is passed
over for the light one: the lean way would take it minutes. The light size, with less than 2.2 GB
left, is made the lean way, 1.2 GB, however little there is. So a PC with 8 GB that has 3 GB left
is asked for 1.7 GB, and one with 4 GB that has 1.5 GB left for 1.2 GB, where 1.7 asked 2.6 GB of
both.

Each measure sits a little under the round number (11.5, 5.5, 7.5 and 15.5 GB), as Windows counts
less memory than a PC is sold with. The card's are estimates until measured on real PCs.

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
`BEZZLE_MATTE_LEAN=1` takes the processor's lean way whatever is left (`0`: never), and
`BEZZLE_MATTE_LEFT=1.5` the ways of a PC with 1.5 GB of memory left;
`BEZZLE_MATTE_MODEL` takes other graphs, a folder of them with their weights or one graph that
every way then runs. The ways, what is remembered of them and the cutouts' names are tested on a
Mac too: `swift test --package-path Windows/Tests`.

**On x64:** tried under Windows' emulation in the Arm VM (2026-11-14), there being no x64 PC here:
`build.ps1 -Arch x64 -Jobs 2 -Product bezzle-render`, then cutouts as above with
`.build\x64\Bezzle\bezzle-render.exe`. It loads ONNX Runtime for x64 and cuts photos out at the
light size: 21 to 22 s a matte after 3.6 to 4.0 s of loading, 1.8 GB in memory (2.4 GB asked).
Given the very input the Arm build gave the model, ONNX Runtime for x64 makes Arm's matte to
within 0.0000035, and its quick and lean ways make the same matte bit for bit as it did as
shipped in 1.7 (1.70 GB and 1.23 GB in memory for 2.69 GB). In a whole cut the x64 build scales
a photo a level or two differently at some 800 of the 3 million numbers the model is given, so
the matte differs by up to 0.007, and 2 values of a million at most fall on the other side of
half. The cutouts' colours are Arm's wherever both are solid, a Display P3 photo's profile and
numbers kept, and their alpha differs at 0.04 to 0.06% of the pixels. Emulation says nothing of
a real x64 processor's speed.

**Not measured:** DirectML has never run this model on a real graphics card, at either size, so
what a card needs and how long it takes are guesses; no PC of 4 or 8 GB has run it; and no real
x64 processor. On the processor, the times of PCs other than the VM are worked out from their
cores.

### Measuring a graphics card

The VM has no Direct3D 12 adapter, so this waits for a real PC: one with a card of 6 GB or more
of its own, and one with integrated graphics. It takes an installed Bezzle (the first version
after 1.7, which says what a matte took and held), a photo of 2,000 pixels or more, and a
Command Prompt:

```
set BEZZLE_TRACE=1
set BEZZLE_MATTE_ROUTE=gpu1024
del "%TEMP%\bezzle-trace.log"
"%LOCALAPPDATA%\Programs\Bezzle\Bezzle.exe"
```

In Bezzle, put the photo into a design and take its background away; then, within half a minute,
a second photo's, whose matte is made with the model still loaded. Quit Bezzle, and read what it
wrote:

```
findstr /c:"subject matte" "%TEMP%\bezzle-trace.log"
```

Three kinds of line answer the questions. What Windows says the PC is:
`subject matte: this PC has … GB, … fast cores, <the card> with … GB of its own`. How long
DirectML took to fit the model to the card:
`subject matte: BiRefNet-1024.onnx at 1024 pixels on DirectML on <the card> (gpu1024), loaded in … s`.
And for each matte, its time and the memory:
`subject matte: gpu1024 on DirectML on <the card>, made in … s; Bezzle has held … GB at most and asked Windows for … GB; the graphics card holds … GB of its own for it now and … GB of the PC's; … GB were free before`.
The first two numbers of memory are the most since Bezzle started, so start it anew for each way.
A way the card cannot make says why instead
(`Bezzle could not make a subject matte (gpu1024): …`), and with the way named alone the cut then
fails rather than taking another.

Do the same with `set BEZZLE_MATTE_ROUTE=gpu2048`, and once without the line, for the way the PC
takes by itself (the last line names it). On integrated graphics `gpu2048` is the way that took
small PCs down up to 1.6: close everything else first. What to bring back for each PC and way:
the three lines, and whether the cutout looks right. The numbers then replace the guesses in
`MatteWays` (`cardForFine`, `cardForLight`, `memoryForCard`, `holds` and `first(cores:)` for the
card). Whether a card's matte is the model's own is checked with a build rather than an installed
Bezzle: `bezzle-render <fonts> cutout <out>` with `BEZZLE_MATTE_RAW` writes the matte's floats,
once with `BEZZLE_MATTE_ROUTE=gpu1024` and once with `cpu1024`, and `compare_mattes.py` compares
the two.

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
