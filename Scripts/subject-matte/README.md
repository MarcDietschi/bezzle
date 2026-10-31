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
