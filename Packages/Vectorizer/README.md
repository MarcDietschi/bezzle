# Vectorizer

Turns a picture into shapes: the engine behind Bezzle's Vectorize. Plain Swift with Foundation
alone, so the Mac app, Bezzle for Windows and a command line can all build it. It is always built
optimized, also inside a Debug build of the app: unoptimized it would take minutes for what takes a
fraction of a second.

```swift
let tracing = Vectorizer.trace(Bitmap(width: w, height: h, pixels: rgba), settings: Settings(detail: 0.5))
for layer in tracing.layers() { … }   // or tracing.shapes, or tracing.svg()
```

A shape or a layer is of one `color`, or has a `blend`: colours running straight across it or
outward from a middle, as stops between two places in the picture. `svg()` writes those as
gradients, and the app makes gradient fills of them (`Bezzle/Model/Vectorizing.swift`, `gradient`).

## How it works

| Step | File | What it does |
|---|---|---|
| Ready | `Raster.swift` | Caps the size (4 megapixels, 0.7 for a draft), measures the noise, tells pixel art, a JPEG's coarse colour (`colorCoarse`) and its ringing beside edges (`ringing`), calms noise with its edges left. A picture scaled up or blurred is brought down to the size at which its edges would be a drawn picture's (`softness`, `resized`) |
| Colours | `Palette.swift` | Finds the colours from where the picture is calm, so the mixed pixels of soft edges make no colours of their own; merges in Oklab; finds the colours of thin strokes, each from the pixels a stroke fills best, so a thin line is its own colour and not a paler one (`drawn`) |
| Samples | `Labels.swift` | Reads the picture at up to 4 by 4 samples to the pixel and gives each its colour. Where a pixel holds an edge between two colours, the edge is placed from how much of each colour the pixels round it hold, which is exact for a straight edge; a thin stroke is placed by the middle and the sum of its shares, also one of a third colour running between two others (`Mixer.triple`), and in a picture that wavers from all seven rows of pixels round it (`strokeAlong`). Each sample also keeps how far it is from the edge found. Thin spurs where three colours meet go to the colours beside them (`withoutSpurs`) |
| Regions | `Labels.swift` (`Regions`) | Samples of one colour that hang together. The pieces of a thin line that came out in several colours are joined into one (`threaded`); a faint fringe along an edge goes to the shapes beside it (`withoutFringes`); specks are taken away by how much detail is wanted, faint ones at a larger size, while something small in one colour all round and nothing like it (the dot of an i, the eye of an e) stays down to a pixel in a picture kept as drawn; in a picture that wavers, short thin pieces left of a line along the edge of two shapes go to those shapes (`withoutSpecks`) |
| Blends | `Blends.swift` | Colours that run: regions of like colours that meet without an edge between them (the border is soft over more than a pixel either side, at most a third of it is not) are taken as one, and the pixels well inside it are fitted with colours running straight across or outward from a middle. It is one region with a `Blend` when that tells every pixel's colour to within the picture's noise and a fifth of how far the colours spread, and when no short stretch holds half of all the change, as an edge out of focus would. The middle of a round run is first taken where the ways the colours change all meet, then moved to where the colours fit best (`settled`), since in a gentle run those ways are half chance. Thin leftovers along its edges go to it. Anything else stays as it was |
| Edges again | `Placing.swift` | Beside a run the palette's colours are each a band's, and an edge read by them lies up to half a pixel off, another way beside each band. With the run known, each such edge is placed again from the colours the two sides have at every pixel: across it, five pixels of a row or a column tell where it crosses, the rows beside tell how it slants, and the samples are given to the side they lie on. In a picture with coarse colour by the pixels' light alone |
| Stack | `Stack.swift` | Broad regions under thin ones, each reaching a little under those over it, so no seam shows; outlines walked along the samples' edges |
| Sides | `Polygon.swift` | Each outline brought down to the fewest straight sides (as Potrace does, with every step counted) |
| Curves | `Curves.swift` (`Fitter`) | Lines laid through where the edge was found between the samples, corners where the lines meet, blunted corners made sharp, curves fitted to the precise steps (Schneider), and rectangles, rounded rectangles, pills and ellipses known for what they are. Where a shape runs on under another, its outline is carried on there in one line, corner or bend (`under`), and straight stretches along one line are one line (`straightened`). Something thin in a picture that wavers has both its edges moved until it is as thick at every place as nearby on the whole (`Evening.swift`) |
| Layers | `Layers.swift` | The shapes as layers for a design: one each, or for a picture with hundreds of them, those of one colour together wherever nothing of another colour lies between; a shape with colours running across it is always a layer of its own |

`Settings`: `detail` (0…1; with little: few colours, nothing small or faint, calmer outlines; with
much: every colour and small thing, the edges as calm as ever), `colors` (at most so many; nil finds
them), `smoothing` (0 follows every turn, 1 runs calm), `draft` (quick and coarser, for showing while
a setting is dragged). `progress` is told how far along the work is and stops it by answering false.

### Pictures that waver

A drawn picture kept as it was drawn (`clean` in `Vectorizer.read`) is taken at its word, pixel by
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
scaling the picture up would give. On 2026-11-14: a logo 0.15 (0.38), the same as a JPEG 0.25 (0.69),
geometric figures 0.03 (0.30), a cartoon 0.03 (0.35), small text 0.15 (0.31), hairlines 0.03
(0.32), pixel art 0.00. `samples` also draws what the engine finds hard, and `score` says of each
what matters in it:

- Hand drawn lines 1 to 3 pixels thick, clean and as a JPEG: how thick each comes out and how much
  that wavers along it. As a JPEG 1.15 to 1.22 for 1 pixel and within 0.03 for the thicker ones,
  wavering 0.06 to 0.08 (as drawn: 0.03 to 0.05).
- A card of colours that run, with shapes on them, as a PNG and a JPEG: 8 shapes for the 7 drawn
  (the ground is in two halves), 5 of them gradients, edges 0.10 and 0.15 px off, colours 0.4 and
  0.6 levels off (as bands of flat colour: 32 and 25 shapes, edges 1.06 and 1.57, colours 4.5 and 6.5).
- 10 point text, also at twice the size, in a light weight and as a JPEG: how many of its pieces are
  there (134 of 140; at twice the size 142 of 142), how many counters are open (36 of 46; 46 of 46)
  and how many letters run together (14; 3).
- A textured picture: its shapes of those drawn (8 of 8).

`against` is the yardstick for pictures that waver. It takes a folder of pictures and a folder with
another tool's SVG of each, of the same name, draws both and says how far this engine's edges lie
from the other's (the pixels that differ, over the length of the other's edges), and how many
shapes and points each needs. The references used are the twelve examples vectorizer.ai shows on its
front page, each a picture and its finished SVG (the `data-bitmap` and `data-vector` addresses in
the page); they are theirs and not kept here. On 2026-11-14, with the settings the app starts with:
edges 0.30 px from theirs on the whole (0.17 to 0.46 a picture), with 0.85 times their points, in
0.03 to 0.45 s a picture; the samples above take 0.12 s at most. (A 512 by 512 photograph took
0.2 s and one of 4 megapixels 0.5 s on 2026-11-10, not measured since.) Shapes: as many as theirs
on logos and mascots (21 of 21, 27 of 27, 25 of 25, 141 where they make 137), more on pictures with
texture and fine lines (243 where they make 193, 113 where they make 87, 129 where they make 105).

What it does not do yet:

- Colours that run are found where they run straight across or outward from one middle, in
  circles. Colours that run round a point, along a bend or outward in ovals stay bands; so does a
  faint run in a noisy picture, where it cannot be told from the noise. `Tracing.palette` still
  lists the bands' colours. In a JPEG the edge of a shape beside a run still has a notch here and
  there, where the pixels across it could not tell.
- 10 point text: strokes and gaps thinner than a pixel. A dot less than a pixel above its stem runs
  into it, the bars of f and t can go, a quarter of the counters close. At twice the size nothing is
  lost. A dot that lies on the corner of four pixels comes out up to three times too large.
- A line a pixel thick in a picture that wavers comes out evenly thick, but about a fifth thicker
  than drawn: its two edges are still found each on its own.
- A picture's finest texture makes more shapes than vectorizer.ai's where thin lines along edges
  break up (the pieces are only taken away where they are short), and in pictures traced at a
  smaller size than their own (those out of focus or scaled up), where nothing is taken away.
