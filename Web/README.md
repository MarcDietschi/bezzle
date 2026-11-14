# Bezzle in the browser: prototype

Bezzle's own model and renderer, compiled from the app's Swift sources to WebAssembly, drawing
real designs through CanvasKit (Skia) in a page. Built on 2026-11-05 to find out whether a web
version can share the Mac app's code and draw designs exactly as the Mac does.

Nothing here is part of the Mac app's build. `Sources/BezzleCore/Shared` links to the app's
sources, so this always compiles the app's code as it stands.

What the web version is for (Erik, 2026-11-05): people without a Mac, on Windows above all,
working on a design someone shared with them. It opens a design only from its invitation link
and makes none of its own, so it keeps no files of its own either.

## What it showed

Measured against the Mac app itself (`tools/WebTruthTests.swift` dumps what Text Kit and the
Core Graphics renderer make of the six sample designs; `tools/compare.mjs` compares):

| | Result |
|---|---|
| Shared Swift compiled unchanged | 19,957 lines in 46 files: all of `Model/` but Live.swift, `Renderer`, `Depth`, `Blurs` |
| Artboards drawn | 17 of 17, 0.3 to 1.1% of pixels off by more than 24 levels (antialiasing at glyph edges) |
| Line breaks | 244 of 244 texts break exactly where the Mac breaks them (12 multi-line) |
| Text heights, first baselines | 244 of 244 identical |
| Text widths | 243 of 244 the same in whole points; of the 232 on one line, 218 within 0.02 pt of the Mac's width and 231 within 0.1 pt (see below) |
| Core's time per artboard | 0 to 54 ms (release build, in Node) |
| Download | core 12.9 MB brotli / 19.8 MB gzip (Bezzle's code < 1 MB of it, the rest Foundation's ICU data); CanvasKit 2.9 MB gzip |

What made text match:

- **SF Pro's `trak` table.** Core Text tracks the system font by size (−0.31 pt a letter at 16
  pt); Skia does not. Applied as letter spacing, line breaks went from 241 to 244 matching.
- **Optical size.** SF Pro is set with `opsz` at the point size (clamped to 17 to 96), as Core
  Text does.
- **Text Kit's line placement**, worked out from the samples (`place` in `WebText.swift`): ascent
  and descent each rounded to whole points, leading not; Skia shares the leading above and
  below, Text Kit does not. With a line spacing, the baseline is the rounded descent and the
  leading up from the line's bottom, raised by half the extra room when lines are further apart
  than the font's own, and not lowered when they are closer.

Widths were measured again on 2026-11-14 with `tools/WidthTruthTests.swift`: 4000 texts on one
line (close pairs, pairs that are not, and words, in the system font and Avenir Next at four and
three weights and Futura, at 25 sizes from 9 to 96 pt, two of them not whole). All break as on the
Mac and are as tall; 3967 are as wide in whole points, the rest a point off. Pairs such as Yo, Ly
and "1," sit as on the Mac, since kerning is left out where the Mac leaves it out (a text whose
letters are not spaced). The system font's spacing between two sizes of its table is cut to
whole units of the font, towards nought, as Core Text cuts it: 3 at 72 pt, where the line from 64
to 80 pt is at 3.5. Kept as a fraction it made a word a quarter of a point wider there. What is
left is the same for every letter and follows no pairs:

- At a size that is not whole, every face is up to a 64th of the size narrower (0.10 pt on a word
  of 230 pt at 27.7 pt). FreeType, which CanvasKit measures letters with, takes sizes in 64ths of
  a point, and Skia cuts 27.7 down to 27.6875.
- In the heavier weights of the system font a letter is up to half a unit of 2048 wider (at Bold
  a quarter of a unit in the mean, 0.2 pt on a word at 96 pt): its width at a weight between the
  font's own comes from FreeType in whole units, from Core Text with its fraction.

Both are inside CanvasKit. `tools/compare.mjs` says how near the texts on one line come to the
Mac's width, which the natural width, in whole points, hides.

With the open fonts (the published page, and Windows, which shares this code), lines are placed
from the Mac's own fonts' measures, not the stand-ins' (`Web/MacFonts.swift`: ascent, descent and
leading of every face the open fonts stand in for, measured with Text Kit; numbers only). So
lines are as tall and baselines where they are on the Mac (Inter's ascent put SF Pro's 16 pt
baseline a point lower, for one). Text Kit's rules, checked at every face and size from 4 to 132
pt: a line is `round(ascent) + round(descent) + leading` with the baseline `round(ascent)` down;
Helvetica, Times, Courier (and Didot and Futura Bold while their leading is under half a point)
get a fifth of that more above; with a line spacing the leading still comes below it; a line of
only a break is rounded; paragraph spacing goes below each paragraph's last line. Skia paints a
line's letters at its ascent rounded to a whole point, not where its line metrics say, and
narrows the layout width to whole points unless its rounding hack is off: both are allowed for.
The stand-ins' letters are spaced to the Mac's widths, by size for Inter (SF Pro is tracked by
size, Inter is not) and once per face for the others, at most 0.03 em (`MacFonts.spacing`); the
page tells the core which families it has stand-ins for (`bz_stand_ins`).

## What the prototype left out, and what is drawn now

`tools/FeatureTruthTests.swift` makes one design, as the Mac writes and draws it, with an artboard
for each thing the prototype was said not to draw, set in the faces `tools/fonts.py` copies, so
that what differs is the drawing and not a font. `tools/compare.mjs` sets the core's drawing
beside the Mac's: in Node, and with `--browser` in a headless Chromium, where there is WebGL
(`tools/headless.mjs`). Pixels off by more than 24 levels, and the mean difference of 255, on
2026-11-14:

| Artboard | Before | Now |
|---|---|---|
| Curves: texts on arcs and waves and riding shapes' outlines | 1.68%, 1.66 | the same to the byte |
| Lists: bullets and numbers with their markers | 2.51%, 2.21 | the same to the byte |
| Paragraphs set apart | 3.17%, 2.58 | the same to the byte |
| Painted: letters filled with a gradient or a picture | 2.07%, 2.01 | the same to the byte |
| Developed: photos developed | 0.21%, 1.27 | the same to the byte |
| Ramp blurs: blurs that grow along a ramp, a layer's own and of what lies behind glass | 21.75%, 12.88 | 0.18%, 1.16 |
| Mixing: plus darker and plus lighter | 26.66%, 13.08 | 0.26%, 0.71 |
| Shaders: four shader fills as the design shows them, in a headless Chromium | 37.08%, 31.2 | 0.13%, 0.21 |

Its 40 texts break as on the Mac. The first five were drawn all along: the shared code that
lays and paints them had come to the viewer with the app's, and what is off is the edges of
letters, as in the samples. What was mended:

- **Plus darker** was drawn as multiply, which is lighter wherever either colour is not white or
  black. Core Graphics' rule was measured (1296 cases): the alphas add up to no more than one, and
  each colour is what that sum leaves once what source and backdrop lack of their own alphas is
  taken away. It is a blender written for CanvasKit (`RuntimeEffect.MakeForBlender`), within one
  step of 255 of the rule; multiply stands in should it not build.
- **A blur that grows along a ramp** was even. The page blurs the picture at seven strengths and
  adds them up, each weighed by how near the ramp is to it there (Windows' host does so with
  five); Core Image's masked variable blur was measured to spread as a Gaussian of the ramp's
  grey times the radius does.
- **A dark rim** lay round every layer with a blur of its own: handed a blur that fades into
  nothing on the paint of `drawImage`, CanvasKit's processor multiplies the colours by their
  alpha once more. The layer is now blurred as a layer of its own.
- **Shader fills** showed their picture in the design and were drawn only in a film. The core now
  asks the page for the fill's frame in the design too, at the fill's own moment, as the Mac's
  `ShaderPainting` does. Without WebGL (in Node), where a program does not build, and for a fill
  beyond plain draws (see Films), the picture stands in.

The 17 sample artboards are drawn the same to the byte before and after each of these.

### The icon library

The icon sets (Lucide, Phosphor, Material Symbols: 7340 icons) are a file beside the app,
`Model/Kits/Icons.deflate`, 2.55 MB of raw DEFLATE. The core has nothing that unpacks DEFLATE
and a page has no bundle to read from, so a page that wants icons fetches the file and calls
`bz.icons(packed)`: the browser's own `DecompressionStream('deflate-raw')` unpacks it and the
core reads it once (`bz_icons`, `WebIcons.swift`; `Icons.unpacked` in the shared code), in 50 to
80 ms; its memory grows by 30 MB. From then on `Icons` answers there as on the Mac: its sets,
the icons found for some words, each icon's outline at a weight. The page a link opens never
asks, and `publish.sh` does not copy the file: an icon in a design is a path like any other, and
only placing a new one needs the library.

`tools/IconTruthTests.swift`, run as WebTruthTests is (below), writes what the Mac reads and a
sheet of 219 icons as it draws them to `<dir>/icons`. `node tools/icons.mjs --truth <dir>`, and
the same with `--browser`: 20 of 20. The same three sets with the same digest of every icon's
name, words and outlines; the same icons in the same order for nine searches; 84 outlines of
Phosphor's and Material's the sets' own; 60 outlines grown from Lucide's lines at weights 0.25 to
6 in the Mac's box within 0.0074 on a box of 24; the sheet, made by the core of its own icons,
0.17% of its pixels off by more than 24 levels and 0.30 of 255 in the mean, where the Mac's own
outlines drawn by the core are 0.13% and 0.29 off.

The sheet brought out three faults of the page's path operations (`pathOp` in
`site/bezzle.mjs`), which no drawing had reached before:

- Making a path simple failed: CanvasKit 0.42 has `makeSimplified` under its inner name alone.
- What Skia combines or makes simple is for filling even-odd, and its contours run either way
  round, so a hole filled by winding may close: a mail icon's lines came out as a filled block
  (2.73% of the sheet off, mean 5.42). Core Graphics promises a path that fills the same by
  either rule. Each contour is now turned by how deep it lies in the others (`wound`; CanvasKit's
  `makeAsWinding` leaves them as they are). Windows' host hands on what Skia makes as it comes
  (`pathOp` in `host.cpp`); whether its icons close up the same way was not tried.
- Skia grows a line into an outline only as truly as a path shown at its own size needs: 0.17
  off at the heaviest weight on a box of 24, which is shown many times larger. It is asked for
  sixteen times as fine.

## Shared designs

The browser opens a shared design with the Mac's own code: its records are JSON of
`SharedDesign`, packed with LZFSE, merged with `SharedDesign.merge` and shown with
`flatDesign().document()`, as `Collaboration` does on the Mac. An edit
becomes a change record of the browser's own with `absorb` and `changes(by:after:)`
(`Web/WebSharing.swift`). `tools/sharing.mjs` tests it without iCloud, on the six sample designs:

| | Result |
|---|---|
| A snapshot the Mac packed (WebTruthTests) | opens as the Mac's own design, byte for byte, all six (up to 232 KB of JSON) |
| Apple's LZFSE and the browser's | read each other both ways |
| An edit in one browser | goes out as a change record of about 195 bytes; a second browser takes it in and shows the same |

Two things had to change for that. `CGFloat` is `Double` (`Platform/CGGeometry.swift`), as on the
Mac: Foundation's is a `Float` on 32-bit WebAssembly, and the browser measured and merged at single
precision (22.33 came back as 22.330017). And the stand-ins live in the core's own module, since
only a module's own declarations shadow Foundation's.

`tools/geometry` compiles that geometry and `CGPath` on the Mac and checks them against Core
Graphics on random cases (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run -c
release` there). Rectangles, points, sizes and transforms agree to the last digit in 8 million
checks, on a coarse grid where edges often touch and off it, where a sum is not exact; for that,
every `x·y + z·w` is fused as a Mac fuses it (`fma(x, y, z·w)`), the inverse goes by the
determinant's reciprocal, and a rectangle is asked whether it holds another by its edges (asked
whether their union is the rectangle itself, it agreed on the grid and was wrong for more than
half the rectangles off it, until 2026-11-14). Rectangles, ellipses and rounded rectangles come out as Core
Graphics makes them; arcs, cut as it cuts them (quarter turns from the start, then the rest when
over √ε), agree within 4e-10. Left: tangent arcs at very sharp angles (2.5e-7 apart), one turning
straight back from its own corner, and a point lying exactly on a curve.

### By link, through the relay (since Bezzle 1.4)

Designs are shared by link through Bezzle's relay on Cloudflare, as `Relay/SHARING.md` lays it
out; iCloud is gone from the app, and the CloudKit route this prototype first took with it.
`site/share.mjs` is the browser's side of that protocol, the same as the Mac's `Sharing` and
`CloudShare`: the keys made from the link's secret (HKDF-SHA256 in WebCrypto), records sealed with
AES-256-GCM under a key of this session's own, the relay's calls, the same rule for which of a
copy's records to read and when to fold them into a whole, picture names by HMAC, and the live
socket that says when there are new records. What the records hold, and how they merge, stays the
core's: `bz_shared_open`, `bz_shared_receive`, `bz_shared_changes`, `bz_shared_whole`.

`site/shared.html` is the page a link opens: `shared.html#2.<secret>` shows the design, with its
name and who shared it, takes in everyone's changes as the relay says they are there, and fetches
pictures as drawings ask for them. It edits nothing: it is for looking at a design, and at who
works on it (below). `?relay=` points it at another relay.

Its words are in English, German, French and Italian, by the first of the visitor's languages it
has (`site/words.mjs`), and where the app or the website says the same thing they are its words:
the app's `Localizable.xcstrings` for what is shared, by whom, and no longer, for artboards and
people; the website's invitation page for a link that is not whole. The app's French says "vous",
the page "tu", like the website. `node tools/words.mjs --site ~/Sites/bezzle-web` holds them to
that (218 checks: every word in every language, written as Bezzle writes, and the same as the
app's and the website's). The film's bar and the live room's labels take their words from there
too. `site/index.html`, the sample viewer for this Mac, is in English alone.

Tested against the relay itself, running here (`cd ../Relay && npx wrangler dev --port 8790`):

| | Result |
|---|---|
| `node tools/link.mjs`: a design shared by one browser, opened from the link by another | the same design; edits both ways; 63 records folded to 40 with two wholes; a copy coming later has everything; pictures whole; nothing opens without the link; unsharing heard at once |
| `node tools/link.mjs --mac <file>` between the two halves of `CloudShareTests.forTheBrowser` (`TEST_RUNNER_BEZZLE_RELAY_TEST`, `TEST_RUNNER_BEZZLE_WEB_LINK=<file>`) | a design the Mac shared opens here as the Mac's to the byte; the browser's edit comes back to the Mac, merged the same |
| `node tools/room.mjs <design.bezzle> --edit`, then `shared.html?relay=http://127.0.0.1:8790#2.<secret>` in Chrome | the page shows the design live, with its pictures, and follows the edits |

### Who else is there

Those who have a shared design open at the same moment meet in its live room on the relay
(`Model/Live.swift`, `Store/LiveRoom.swift`): each says who they are, where their hand is, what
they hold, and what they change as they change it. The page is in that room to watch.
`share.mjs`' `follow` hears who comes and goes and opens what is said (sealed as the records are,
about `live`). The core reads it with the Mac's own code: `Model/LiveMessages.swift` has the
messages, how they travel, whose pencil is whose and the loop a pencil draws, and `WebLive.swift`
keeps who is there, the artboard a hand is over and the outline of each layer held
(`Perspective`). `site/live.mjs` draws it as `LiveMarks` and `LiveViews` do on the Mac, the same
shapes, sizes and timing:

- a token for each person in the bar at the top, in their pencil, ringed while they are at work
  and dimmed while they are away; pointed at, their name hangs below it, with their time where it
  is not the time here; pressed, it shows the artboard they are on;
- a dot in their pencil beside that artboard's name in the list;
- over the artboard their hand, shaped like the tool they hold, gliding to where it is; their name
  beside it when they have just come, start moving after a rest, type or move a layer, or when
  the visitor's own pointer is near; what they hold, outlined, with their initial on a flag; the
  loop they draw by shaking their pointer;
- what they change, as they change it, before it is in the room's records. The record that
  follows changes nothing and is not drawn again (`bz_shared_receive` answers `same`);
- someone silent for 25 seconds shows as away, and after five minutes as gone, as on the Mac.

The page never says who it is (`LiveHello`), so nobody is shown it: it has no pencil and stands
in nobody's list. A Mac tells those it has heard from in the last five minutes where its hand is.
So while the page's tab is in sight and others are there, it says every two minutes that it still
watches, with a message that wants nothing (`{"want":{"_0":[]}}`, sealed), which a Mac answers
only by saying who it is.

Not shown: a layer moving while it is dragged (it moves when the drag ends), the glow of what was
just changed, the light where others look (the list's dots say which artboard), pictures on their
way, and following someone's view. While an artboard shows its film, nothing is drawn over it.

| | Result |
|---|---|
| `tools/LiveTruthTests.swift`, run as WebTruthTests is (below): two real rooms and a watcher on a relay of the test's own | a Mac alone with a watcher tells it who it is and where; neither Mac ever counts the watcher among the people; the watcher's word that it is still there is answered by each Mac saying who it is. Writes `<dir>/live/live.json`: the 21 messages the watcher was sent, and what each Mac showed of the other after every step |
| `node tools/live.mjs --truth <dir>` | 25 of 25: the core reads the 21 messages (2 of them packed with LZFSE) as the Macs read them, the same people, pencils, tools, pointers and outlines of held layers, the wink where the Mac has it and fading at its pace; the design after each of three changes is the Mac's to the byte; rooms of 1 to 10 are handed the Mac's pencils; four loops lie within 7e-15 points of the Mac's |
| The same with `--relay http://127.0.0.1:8791` (`cd ../Relay && npx wrangler dev --port 8791`): the page in a headless Chromium, stand-ins saying the Macs' words in its room | 68 of 68: tokens in the bar in the Macs' pencils at every step; held layers outlined and the hand drawn in those pencils, read from the page's pixels; the hand glides to the Mac's pointer; the list says who is on which artboard and a token goes there; a wink is drawn; three changes show as they are made, the design the Mac's to the byte, and the five records that follow draw nothing again; silence shows as away, then gone; the page says nothing in the room but that it is still there, and nothing at all while its tab is hidden |

Two faults of a core whose `Int` has 32 bits came out this way, and are mended in the shared
code: a pencil was chosen by four bytes read into an `Int` (a trap for every second name), and a
loop's random numbers were divided by `1 << 53`, which is 0 there.

## Films

An artboard with a film (Animate) can be played in the page. It opens as the design, as it always
did, with a quiet bar under it: a round button plays and stops the film, a thin track takes it to
any moment, the time stands beside it, and the space bar plays and stops too. The film goes round
with a breath of 0.7 s at its end, or plays once where it says so (`film.once`), as on the Mac; the
artboard's name in the list shows the design again. A design without a film gets no bar and is
drawn as before: all 17 sample artboards come out the same to the byte.

It is drawn the way the Mac's movie is (`FilmExport.Reel`), from the same arithmetic
(`Model/Film.swift`; `Bezzle/Canvas/FilmPictures.swift` is linked into `Sources/BezzleCore/Film`).
`Film/WebFilm.swift` keeps a picture of each piece and answers, for a moment, the pieces from the
furthest to the nearest: each with the 3×3 map that takes its picture onto the frame, how much of
it shows, its blur, and its outline where it reaches behind the eye. The page only places them
(`compose` in `site/bezzle.mjs`), so the camera's perspective, fades and blurs are the graphics
card's work. What keeps it quick and true:

- **A piece whose insides change** (a path drawn on, a shape reshaped, a shader that moves, layers
  moving inside a faded group) is drawn again for each moment, into a picture made on the graphics
  card. Every other piece is drawn once.
- **Sharp at rest.** While the film plays, a piece is as sharp as its whole picture, 4096 pixels a
  side and 16 megapixels at most. Where the film rests, the part of a piece that shows larger than
  its picture holds is drawn again as sharp as it is seen and laid over it, as on the Mac.
- **Pictures made ahead**, one every 20 ms from when the artboard is shown, and each put on the
  graphics card then, so playing does not wait for them (`bz_film_warm`).
- **Nothing kept.** The core says which pictures and texts it has let go (`drop` and `dropTexts`
  in every answer), and the page forgets them: after a film none of its pictures is held (see
  What the page keeps, below). A surface on the processor gives its pixels back only to
  CanvasKit's `dispose`, not `delete` (`raster` in `site/bezzle.mjs`): with `delete`, a film
  played in Node kept a frame's pixels at every moment, 1.8 GB after 500 and then an abort; now
  CanvasKit's memory stays at 128 MB over 1800, also for a film that has a text set anew at every
  moment (a text that breaks its lines at its width, growing by a key inside a piece drawn again).
- **Shader fills** are drawn with WebGL, which their programs were written for (`site/shaders.mjs`,
  asked through `Web/WebShaderPainting.swift`): in a film at the film's moment, in the design at
  the fill's own, the part of the layer its picture shows. Where there is no WebGL, the fill's
  picture stands in. So it does for a fill that draws through textures first or with depth,
  stencil, instances or textures of numbers (`ShaderFill.beyondPlain`, kept under `Fill`'s key
  `scene`): `shaders.mjs` draws a fill's draws onto its canvas and nothing more.
- **Without WebGL** the same frames are made by Skia on the processor and put on the canvas: right,
  and slow.

Measured against the Mac: `tools/FilmTruthTests.swift` makes three designs with a film and writes
frames of each as a movie's are made (`FilmExport.frame`, 2 pixels a point), with where the film's
arithmetic puts every piece; `tools/film-compare.mjs` compares. In Playwright's headless Chromium
(ANGLE on Metal, Apple M5 Pro, a screen turning 60 times a second), 2026-11-14:

| | Depth, 480×320 pt | Lines, 420×300 pt | Flight, 393×852 pt |
|---|---|---|---|
| What it holds | a camera moving in depth, fades, a blur, springs; plays once on its own backdrop | a shader moving by itself and by a key, lines drawn on, a star and a drop reshaped, the camera drawing near and turning | Wander's first artboard, its layers rising one after another under a camera flying in close |
| Moments compared | 9 | 7 | 8 |
| Every piece's place, order, opacity, blur | the Mac's, 0.0 pt apart | the Mac's, 0.0 pt apart | the Mac's, 0.0 pt apart |
| Pixels off by more than 24 levels, graphics card | 0.45% (worst frame 0.81%) | 0.20% (0.24%) | 1.17% (2.67%) |
| The same, processor | 0.36% (0.58%) | 0.34% (0.43%) | 0.63% (1.07%) |
| Mean difference of 255, graphics card and processor | 0.52 and 0.50 | 0.65 and 0.73 | 1.63 and 1.02 |
| Frames a second playing, graphics card | 60.1 at 960×640 | 60.1 at 840×600 | 60.0 at 786×1704 |
| A frame there: core, making pictures, placing | 0.6, 0.2, 0.7 ms | 3.7 (2.9 of it the shader), 0.4, 0.2 ms | 0.3, 0, 0.4 ms |
| Longest wait for a frame | 17 ms | 17 ms | 17 ms |
| Frames a second, processor | 10.4 | 12.1 | 4.9 |

The differences lie on edges and in the photographs' detail, as the stills' do. These are against
the frames the Mac writes now, with the core as it stands and the Mac otherwise quiet; of six
times Depth was played, one had a single frame 100 ms late. Since a movie cuts gentle tones to
its steps once, from pieces kept finer than eight bits (`FilmExport`, 7ec4e10), the Mac's frames
are up to 2 levels of 255 from what they were, in two pixels of five in Lines; the page still
draws each piece with eight bits. That is the whole of Lines' mean going from 0.47 and 0.68 to
0.65 and 0.73: against the frames from before that change every number of the table is as it
was first measured (0.44%, 0.20%, 1.17% of pixels off; means 0.52 and 0.49, 0.47 and 0.68, 1.62
and 1.01), and no more pixels are off by more than 24 levels against either.

In the page a link opens it was tried through a relay on this Mac (`node tools/room.mjs <a design
with a film> --relay <address> --edit`, then `shared.html?relay=<address>#2.<secret>` in the same
headless Chromium): the film plays on while the design's edits come in, a film resting at a moment
stays there, and the button says what it does in the page's four languages.

## What the page keeps

The core only describes: the page makes the pictures (CanvasKit images) and sets the texts
(paragraphs). It keeps each for as long as the core holds it, and every answer of the core names
the pictures and texts it holds no more (`drop`, `dropTexts`; `PageKeeps.swift`, `took` in
`site/bezzle.mjs`):

- **A picture** is held by what draws it: the artboard last drawn as the design, until the next is
  drawn or another design opened; a film's piece while the film shows it; a blur or a developed
  photo while the core's cache has it; one of the design's own photographs while the design is
  open. So the picture `render` answers is the page's until the next drawing: a caller reads its
  pixels at once, as the pages do.
- **A text** is held by its layout in the core and by every picture that draws it (`HostTexts`,
  kept with a recording as the pictures it draws are). The core forgets the layouts longest not
  asked for once it has more than three for every layer of the design, and 1200 at least
  (`TextLayout.trim`): a design's own texts are never set twice, and texts set anew again and
  again (one growing in a film, a shared design changed by others for hours) go.
- **A paragraph costs little** since all are made from one font collection. Made from the font
  provider, each had a collection of its own and with it a copy of every weight and optical size
  of the system font it was set in (0.12 MB a paragraph, a third of it never given back), and a
  face's leading was read from a typeface made anew from the face's data for every size (0.43 MB
  each time for Avenir Next Regular, never given back): together the 0.3 MB a text that was
  measured before.

Measured on 2026-11-14, every artboard of a design drawn twenty times round at 2 pixels a point,
as a shared design is drawn again at each edit (CanvasKit's memory is what its heap has grown to;
459 MB of Wander Night's is its photographs, held before anything is drawn):

| | Pictures held and CanvasKit's memory, before | Now |
|---|---|---|
| Wander Night, 6 artboards, Node | 270, 1136 MB | 31, 551 MB |
| The same in a headless Chromium | 270, 1139 MB | 31, 551 MB |
| The same with an edit before each of 30 rounds, Node | 506, 1529 MB | 31, 551 MB |
| Adoption Day Sizes, 4 artboards, Node | 161, 2027 MB | 3, 221 MB |
| Features (above), 8 artboards, Node | 195, 1254 MB | 36, 184 MB |
| The same in a headless Chromium, its shaders drawn | 274 and 80 shader frames, 1246 MB | 39 and 4, 154 MB |
| One artboard (Adoption Day) 400 times, Node | 656 MB after 20, 28 MB more a drawing | 184 MB from the 80th on |
| A film with a text set anew at every moment, 1800 moments, Node | 1230 MB (319 MB with every text let go and the film opened again each 600) | 128 MB, 600 to 1200 texts held, 2405 let go one by one, the film never opened again |

Every drawing came out the same to the byte as the first of its artboard, before and now, and so
do a frame of the film played long and the design after it.

## How it is put together

- `Sources/BezzleCore/Platform`: Core Graphics for WebAssembly, in the core's own module (see
  above). `CGFloat` is `Double`; `CGPoint`, `CGSize` and `CGRect` follow Core Graphics' rules as a
  Mac answered them (null is (inf, inf, 0, 0), rectangles are standardized first, `contains` is
  half-open, touching rectangles do not intersect). `CGPath` in Swift (boolean operations, stroke
  outlines and dashes by Skia, through the page); `CGContext` records every call, keeping Core
  Graphics' state and space (y up, shadows in device pixels, transparency layers) so the
  renderer's own questions get the answers Core Graphics would give. `CGImage` is a description:
  a design's picture, an offscreen recording, or one of those blurred or bent. Also as little of
  AppKit, Core Image, CryptoKit, ImageIO and QuartzCore as the shared code asks for, and LZFSE
  for `NSData.compressed`.
- `Sources/CoreGraphics`, `AppKit`, `CoreImage`…: empty modules, so the shared sources' imports
  find one. They bring Foundation, as the frameworks do.
- `Sources/LZFSE`: Apple's LZFSE, which shared designs are packed with (see its README).
- `Sources/BezzleCore/Web`: what is the app's but not shared yet. `WebText.swift` is TextLayout with
  Skia's paragraphs behind it; `WebStandIns.swift` holds pictures from the page, and small copies
  of things the model reaches into the app for (see below).
- `prepare.sh`: copies the few shared files that need a line changed (Blurs.swift's
  `CoreImage.CIFilterBuiltins` import; DesignTokens.swift's CGFloat overload of `number`, the
  same as its Double one here) or only part taken (the reach functions of BoardTiles.swift,
  `Preset` from Library.swift).
- `Sources/BezzleCore/Film`: a film for the page (see Films). `WebFilm.swift` is the browser's
  own; `FilmPictures.swift` links to the Mac's. Windows, which shares `Platform`, `Shared` and
  `Web`, does not take this folder: it has its own stage.
- `Sources/BezzleCore/Main.swift`: what the page calls (`bz_…`), each answering JSON. Beside it,
  the browser's own and not Windows': `PageKeeps.swift` (what the page may let go, see What the
  page keeps), `WebLive.swift` (who else is there) and `WebIcons.swift` (the icon library).
- `site/bezzle.mjs`: the page's side, for a browser or Node. A small WASI, the host calls (path
  operations, pictures, text, shaders), the playback of the recording with CanvasKit, and a
  film's frames (`film`, `filmFrame`, `filmDraw`, `filmWarm`, `filmClose`).
- `site/shared.html`: the page a link opens (see Shared designs), with `site/share.mjs` (the
  relay's protocol and the live room's socket), `site/live.mjs` (the others' tokens, hands and
  outlines) and `site/words.mjs` (its words in four languages).
- `site/film.mjs`: the bar under an artboard with a film, and the canvas its frames are drawn on,
  which lies exactly over the design's. `createScreen` alone is that canvas, for tools.
- `site/shaders.mjs`: shader fills drawn with WebGL 1 or 2, as their programs ask, a part of the
  drawing buffer at a time.
- `site/index.html`: a viewer of the sample designs, or of any `.bezzle` folder opened;
  `?package=<address of a .bezzle folder>` opens one by its address.

## What the model takes from the app today

To share the model as it is, these would move into `Model/`: `Guide` and `Helpers` (Store, for
snapping), `Node.freshCopy` and `Components.freshCopy` (Store), `Preset` (Store/Library.swift, for
Adapt), `CGRect.area` (DocumentStore.swift), `CanvasView.normalized` (an angle helper), and the
platform-neutral half of `TextLayout.swift` (the `Node` extension at its end).

## Not done in the prototype

- **Any editing UI.** It was built once and taken out at Erik's wish: the page is for looking.
  With it goes placing an icon, which the core could now do (The icon library, above).
- **Shader fills** with passes into textures, steps that build on the frames before, tests and
  masks, instances or textures of numbers: their picture stands in, in a film too. So it does
  for every shader fill where there is no WebGL.
- **Of the live room**: a layer moving while someone drags it (it moves when the drag ends), the
  glow of what was just changed, the light where others look, pictures on their way, following
  someone's view (Who else is there, above).
- **Words** of `site/index.html`, the sample viewer for this Mac: English alone.
- **Widths** at sizes that are not whole and in the system font's heavier weights, by up to 0.2
  pt on a word: inside CanvasKit (What it showed, above).
- **A film's gentle tones**: the page draws each piece of a film with eight bits, where the Mac's
  movie keeps its pieces finer and cuts to eight once. Up to 2 levels of 255 (Films, above).
- **Not set beside the Mac yet**: what the shared code gained on 2026-11-13 and 14 (3D bodies
  and the look from the side, groups that keep depth, Shape keys with other outlines, looks
  keyed in a film). It is compiled into the core as it stands; no truth design holds it.

Drawn or done since, and proven against the Mac above: text on curves, list markers, paragraph
spacing, letters painted with a gradient or a picture, developed photos, blurs that grow along a
ramp, "plus darker", shader fills in the design, who else is there with their hands, the icon
library, the page's words in four languages.

## Building and running

Needs the swift.org toolchain 6.4.2 and its WebAssembly SDK (Xcode's Swift cannot target
WebAssembly). Both install per user, beside Xcode:

```sh
installer -pkg swift-6.4.2-RELEASE-osx.pkg -target CurrentUserHomeDirectory
~/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift sdk install swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz
```

Then:

```sh
./build.sh -c release -Xswiftc -Osize -Xlinker --strip-all   # the core
npm install                                                  # CanvasKit
python3 -m venv venv && venv/bin/pip install fonttools && venv/bin/python -I tools/fonts.py
python3 tools/samples.py
```

`tools/fonts.py` copies Apple's fonts into `site/fonts` for testing on this Mac. **They may not
be published**: the folder is git-ignored and must stay out of any deploy.

To compare with the Mac, copy `tools/WebTruthTests.swift` into `BezzleTests/` of a copy of the
repository (`git archive HEAD`), run it with `TEST_RUNNER_WEB_TRUTH_OUT=<dir>` and
`TEST_RUNNER_WEB_TRUTH_DESIGNS=<AppStore/screenshots-src/designs>`, then
`node tools/compare.mjs --truth <dir> --designs ../AppStore/screenshots-src/designs --wasm .build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm`.
Pictures and differences go to `out/`, or `--out <dir>`.

The other truths are made the same way, each a test copied into `BezzleTests/` beside it and
writing a folder of its own under `<dir>`:

| Test | Writes | Compared by |
|---|---|---|
| `FeatureTruthTests` | `features`: a design of what the prototype left out, drawn | `tools/compare.mjs --truth <dir>/features --designs <dir>/features`, and again with `--browser` for its shader fills |
| `WidthTruthTests` | `widths`: 4000 texts on one line, measured | the same, on `<dir>/widths`: its report has each text's `dWidth` |
| `IconTruthTests` | `icons`: the icon sets as read, a sheet of icons drawn | `tools/icons.mjs --truth <dir> [--browser]` |
| `LiveTruthTests` | `live`: what two Macs said in a live room and showed of each other | `tools/live.mjs --truth <dir> [--relay <a relay on this Mac>]` |
| `FilmTruthTests` | `films`: three designs with a film, frames of each | `tools/film-compare.mjs --truth <dir>` (below) |

`--browser` draws in a headless Chromium of the tools' own (`tools/headless.mjs`: Playwright's
from `~/Library/Caches/ms-playwright`, or `--chrome <path>`; never a window of one's own Chrome),
served from this Mac alone.

Films are compared the same way: copy `tools/FilmTruthTests.swift` into `BezzleTests/`, run it
with the same two variables (its designs, frames and `films.json` go to `<dir>/films`), then
`node tools/film-compare.mjs --truth <dir>`. That compares in Node, where there is no WebGL, so a
film with a shader is only right with `--browser`: the page's own `film.mjs` in a headless
Chromium (Playwright's from `~/Library/Caches/ms-playwright`, or `--chrome <path>`; never a
window of one's own Chrome), once on the graphics card and once on the processor. `--fps 6` plays
each film there for six seconds as the page plays it and says how many frames a second it kept
and what a frame cost. Frames, differences and `report*.json` go to `out/films`, or `--out <dir>`.

To look at it in a browser, serve the repository's root (`python3 -m http.server 8765 --bind 127.0.0.1`)
and open http://127.0.0.1:8765/Web/site/index.html.

## Hosting

The page is static files and the core is single-threaded, so it needs no cross-origin isolation
headers. It sits in bezzle-web's `public/app/`, published at https://bezzle.ch/app/, view only.

To publish a new core or page (at Erik's word only): build the core as above, run
`venv/bin/python -I tools/openfonts.py` once (it makes the git-ignored `site/openfonts/`, the open
look-alikes the page uses in place of Apple's faces, from `tools/mac-faces.json`; the Windows build
takes them too), then `./publish.sh ~/Sites/bezzle-web`, which writes
`public/app/` there and commits nothing. Committing and pushing bezzle-web then deploys it to bezzle.ch
(its `README.md` › Deploying). Apple's own fonts never go into it.

What does not fit there: threads for drawing tiles in parallel (they need those headers, which the website's
`.htaccess` could send now that it is on its own server). The invitation page, open.html, is the way
in: without Bezzle installed it can open the design in the browser instead. A first visit loads
about 22 MB; a core on FoundationEssentials alone would be a fraction of that.
