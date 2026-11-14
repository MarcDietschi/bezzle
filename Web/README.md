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
| Artboards drawn | 17 of 17, 0.3 to 1.7% of pixels off by more than 24 levels (antialiasing at glyph edges) |
| Line breaks | 244 of 244 texts break exactly where the Mac breaks them (12 multi-line) |
| Text heights, first baselines | 244 of 244 identical |
| Text widths | 230 of 244 within 1 pt; the rest within 6 pt (SF Pro and Avenir kerning, see below) |
| Core's time per artboard | 0 to 46 ms (release build, in Node) |
| Download | core 12.8 MB brotli / 19.3 MB gzip (Bezzle's code < 1 MB of it, the rest Foundation's ICU data); CanvasKit 2.9 MB gzip |

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

Still open: a few SF Pro and Avenir words come out up to 0.2 pt a letter narrower. The difference
follows kerning pairs (Yo, Ly, "1,") at some sizes, not tracking.

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
release` there). Rectangles, points, sizes and transforms agree to the last digit in 4.4 million
checks; for that, every `x·y + z·w` is fused as a Mac fuses it (`fma(x, y, z·w)`), and the inverse
goes by the determinant's reciprocal. Rectangles, ellipses and rounded rectangles come out as Core
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
pictures as drawings ask for them. It edits nothing yet. `?relay=` points it at another relay.

Tested against the relay itself, running here (`cd ../Relay && npx wrangler dev --port 8790`):

| | Result |
|---|---|
| `node tools/link.mjs`: a design shared by one browser, opened from the link by another | the same design; edits both ways; 63 records folded to 40 with two wholes; a copy coming later has everything; pictures whole; nothing opens without the link; unsharing heard at once |
| `node tools/link.mjs --mac <file>` between the two halves of `CloudShareTests.forTheBrowser` (`TEST_RUNNER_BEZZLE_RELAY_TEST`, `TEST_RUNNER_BEZZLE_WEB_LINK=<file>`) | a design the Mac shared opens here as the Mac's to the byte; the browser's edit comes back to the Mac, merged the same |
| `node tools/room.mjs <design.bezzle> --edit`, then `shared.html?relay=http://127.0.0.1:8790#2.<secret>` in Chrome | the page shows the design live, with its pictures, and follows the edits |

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
- **Nothing kept.** The core says which pictures it has let go (`drop` in every answer), and the
  page forgets them: after a film none of its pictures is held. A surface on the processor gives
  its pixels back only to CanvasKit's `dispose`, not `delete` (`raster` in `site/bezzle.mjs`):
  with `delete`, a film played in Node kept a frame's pixels at every moment, 1.8 GB after 500 and
  then an abort; now CanvasKit's memory stays at 154 MB over 1200. A text is kept as long as the
  core keeps its own copy of it, and a film can have one set anew at every moment (a text that
  breaks its lines at its width, growing by a key inside a piece drawn again), about 0.3 MB each
  time: 647 MB after 900 moments. So once a film has had 600 more texts set than the page held
  when it opened, every text is let go on both sides and the film opened again (`mostTexts` in
  `site/bezzle.mjs`): 319 MB however long it plays, for a wait as at the film's start every 600
  texts. Frames and the design come out the same to the byte after it.
- **Shader fills** are drawn with WebGL, which their programs were written for (`site/shaders.mjs`,
  asked through `Web/WebShaderPainting.swift`): in a film, at the film's moment, the part of the
  layer its picture shows. In the design itself, and where there is no WebGL, the fill's picture
  stands in as before.
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
| Pixels off by more than 24 levels, graphics card | 0.44% (worst frame 0.81%) | 0.20% (0.24%) | 1.17% (2.67%) |
| The same, processor | 0.36% (0.58%) | 0.34% (0.43%) | 0.63% (1.07%) |
| Mean difference of 255, graphics card and processor | 0.57 and 0.54 | 0.47 and 0.68 | 1.62 and 1.01 |
| Frames a second playing, graphics card | 60.0 at 960×640 | 59.9 at 840×600 | 60.2 at 786×1704 |
| A frame there: core, making pictures, placing | 0.5, 0.2, 0.8 ms | 4.1 (3.0 of it the shader), 0.6, 0.3 ms | 0.2, 0, 0.3 ms |
| Longest wait for a frame | 33 ms, the first | 33 ms, the first | 17 ms |
| Frames a second, processor | 7.7 | 8.5 | 2.8 |

The differences lie on edges and in the photographs' detail, as the stills' do. The Mac was busy
with other builds while this ran.

In the page a link opens it was tried through a relay on this Mac (`node tools/room.mjs <a design
with a film> --relay <address> --edit`, then `shared.html?relay=<address>#2.<secret>` in the same
headless Chromium): the film plays on while the design's edits come in, a film resting at a moment
stays there, and the button says what it does in the page's four languages.

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
- `site/bezzle.mjs`: the page's side, for a browser or Node. A small WASI, the host calls (path
  operations, pictures, text, shaders), the playback of the recording with CanvasKit, and a
  film's frames (`film`, `filmFrame`, `filmDraw`, `filmWarm`, `filmClose`).
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

Text on curves, list markers, paragraph spacing, letters painted with a gradient or picture,
photo develop, blurs that grow along a ramp, "plus darker" mixing (drawn as multiply), shader
fills outside a film (the design shows their picture), live co-working's pointers and presence
(the page hears only that there are new records), the icon library (needs zlib), localization
(English only), any editing UI.

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
Pictures and differences go to `out/`.

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
