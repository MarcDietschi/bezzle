# Vectorizer

Turns a picture into shapes: the engine behind Bezzle's Vectorize. Plain Swift with Foundation
alone, so the Mac app, Bezzle for Windows and a command line can all build it. It is always built
optimized, also inside a Debug build of the app: unoptimized it would take minutes for what takes a
fraction of a second.

```swift
let tracing = Vectorizer.trace(Bitmap(width: w, height: h, pixels: rgba), settings: Settings(detail: 0.5))
for layer in tracing.layers() { … }   // or tracing.shapes, or tracing.svg()
```

## How it works

| Step | File | What it does |
|---|---|---|
| Ready | `Raster.swift` | Caps the size (4 megapixels, 0.7 for a draft), measures the noise, tells pixel art and JPEG's coarse colour, calms noise with its edges left. A picture scaled up or blurred is brought down to the size at which its edges would be a drawn picture's (`softness`, `resized`) |
| Colours | `Palette.swift` | Finds the colours from where the picture is calm, so the mixed pixels of soft edges make no colours of their own; merges in Oklab; finds the colours of thin strokes |
| Samples | `Labels.swift` | Reads the picture at up to 4 by 4 samples to the pixel and gives each its colour. Where a pixel holds an edge between two colours, the edge is placed from how much of each colour the pixels round it hold, which is exact for a straight edge; a thin stroke is placed by the middle and the sum of its shares, also one of a third colour running between two others (`Mixer.triple`), and in a picture that wavers from all seven rows of pixels round it (`strokeAlong`). Each sample also keeps how far it is from the edge found. Thin spurs where three colours meet go to the colours beside them (`withoutSpurs`) |
| Regions | `Labels.swift` (`Regions`) | Samples of one colour that hang together. The pieces of a thin line that came out in several colours are joined into one (`threaded`); a faint fringe along an edge goes to the shapes beside it (`withoutFringes`); specks are taken away by how much detail is wanted, faint ones at a larger size (`withoutSpecks`) |
| Stack | `Stack.swift` | Broad regions under thin ones, each reaching a little under those over it, so no seam shows; outlines walked along the samples' edges |
| Sides | `Polygon.swift` | Each outline brought down to the fewest straight sides (as Potrace does, with every step counted) |
| Curves | `Curves.swift` (`Fitter`) | Lines laid through where the edge was found between the samples, corners where the lines meet, blunted corners made sharp, curves fitted to the precise steps (Schneider), and rectangles, rounded rectangles, pills and ellipses known for what they are. Where a shape runs on under another, its outline is carried on there in one line, corner or bend (`under`), and straight stretches along one line are one line (`straightened`) |
| Layers | `Layers.swift` | The shapes as layers for a design: one each, or for a picture with hundreds of them, those of one colour together wherever nothing of another colour lies between |

`Settings`: `detail` (0…1; with little: few colours, nothing small or faint, calmer outlines; with
much: every colour and small thing, the edges as calm as ever), `colors` (at most so many; nil finds
them), `smoothing` (0 follows every turn, 1 runs calm), `draft` (quick and coarser, for showing while
a setting is dragged). `progress` is told how far along the work is and stops it by answering false.

### Pictures that waver

A drawn picture kept as it was drawn (`clean` in `Vectorizer.trace`) is taken at its word, pixel by
pixel. Any other, a JPEG, a noisy or a scaled one, has edges that waver, and an outline that follows
them has a point at every waver. For those the engine measures how far the edges waver (`wobbles`,
the third difference along every outline) and lets every outline stray that much more (`loose`, 1.5
to 3 times): the polygon's slack, the curves' tolerance, how flat a side must be to be a line, how
blunt a corner may be and still be sharp, and how far a shape reaches under its neighbours all grow
by it.

## Working on it

```sh
swift build -c release
.build/release/vectorize-cli samples <folder>            # draws the test pictures and their truth at 4×
.build/release/vectorize-cli score <folder> --keep <out> # traces each and measures it against the truth
.build/release/vectorize-cli trace picture.png out.svg --png out.png --zoom 4
.build/release/vectorize-cli against <pictures> <references> --keep <out>   # measures tracings against another tool's
.build/release/vectorize-cli show file.svg out.png --zoom 4 --crop x,y,w,h --nodes   # any SVG, with its points
.build/release/vectorize-cli pixels picture.png out.png --zoom 12 --crop x,y,w,h     # a picture's pixels, enlarged
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`score` says how far the traced edges are from the true ones, in pixels of the picture, beside what
scaling the picture up would give. On 2026-11-10: a logo 0.15 (0.38), the same as a JPEG 0.24 (0.69),
geometric figures 0.03 (0.30), a cartoon 0.03 (0.35), 10 point text 0.17 (0.31), hairlines 0.03
(0.32), pixel art 0.00. A 512 by 512 photograph takes 0.2 s, one of 4 megapixels 0.5 s.

`against` is the yardstick for pictures that waver. It takes a folder of pictures and a folder with
another tool's SVG of each, of the same name, draws both and says how far this engine's edges lie
from the other's (the pixels that differ, over the length of the other's edges), and how many
shapes and points each needs. The references used are the twelve examples vectorizer.ai shows on its
front page, each a picture and its finished SVG (the `data-bitmap` and `data-vector` addresses in
the page); they are theirs and not kept here. On 2026-11-10, with the settings the app starts with:
edges 0.30 px from theirs on the whole (0.16 to 0.48 a picture), with 0.90 times their points, in
0.04 to 0.45 s a picture. Shapes: as many as theirs on logos and mascots (21 of 21, 27 of 27, 25 of
25), more on pictures with texture and fine lines (298 where they make 193, 161 where they make 87).

What it does not do yet: colours that run across a shape are traced as bands of flat colour, not as
gradients (`Blend` is there for it and unused); 10 point text loses some of its smallest pieces. A
line about a pixel thick in a picture that wavers comes out whole, but its two edges are fitted
each on its own, so its thickness still wavers a little where vectorizer.ai's is even; and such a
picture's finest texture makes more shapes than theirs.
