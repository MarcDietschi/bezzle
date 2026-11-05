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
Core Graphics renderer make of the six App Store sample designs; `tools/compare.mjs` compares):

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

## How it is put together

- `Sources/CoreGraphics`: Core Graphics for WebAssembly. `CGPath` in Swift (boolean operations,
  stroke outlines and dashes by Skia, through the page); `CGContext` records every call, keeping
  Core Graphics' state and space (y up, shadows in device pixels, transparency layers) so the
  renderer's own questions get the answers Core Graphics would give. `CGImage` is a description:
  a design's picture, an offscreen recording, or one of those blurred or bent.
- `Sources/CoreImage`, `AppKit`, `CryptoKit`, `ImageIO`, `QuartzCore`: as little of each as the
  shared code asks for. Core Image's blur and perspective become descriptions for the page.
- `Sources/BezzleCore/Web`: what is the app's but not shared yet. `WebText.swift` is TextLayout with
  Skia's paragraphs behind it; `WebStandIns.swift` holds pictures from the page, and small copies
  of things the model reaches into the app for (see below).
- `prepare.sh`: copies the few shared files that need a line changed (Blurs.swift's
  `CoreImage.CIFilterBuiltins` import) or only part taken (the reach functions of
  BoardTiles.swift, `Preset` from Library.swift).
- `site/bezzle.mjs`: the page's side, for a browser or Node. A small WASI, the host calls (path
  operations, pictures, text) and the playback of the recording with CanvasKit.
- `site/index.html`: a viewer of the sample designs, or of any `.bezzle` folder opened.

## What the model takes from the app today

To share the model as it is, these would move into `Model/`: `Guide` and `Helpers` (Store, for
snapping), `Node.freshCopy` and `Components.freshCopy` (Store), `Preset` (Store/Library.swift, for
Adapt), `CGRect.area` (DocumentStore.swift), `CanvasView.normalized` (an angle helper), and the
platform-neutral half of `TextLayout.swift` (the `Node` extension at its end).

## Not done in the prototype

Text on curves, list markers, paragraph spacing, letters painted with a gradient or picture,
photo develop, blurs that grow along a ramp, "plus darker" mixing (drawn as multiply), live
co-working (Live.swift uses CryptoKit's ChaChaPoly; the browser has WebCrypto), the icon
library (needs zlib), localization (English only), any editing UI.

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

To look at it in a browser, serve the repository's root (`python3 -m http.server 8765 --bind 127.0.0.1`)
and open http://127.0.0.1:8765/Web/site/index.html.

## Hosting

The page is static files and the core is single-threaded, so it needs none of the
cross-origin isolation headers GitHub Pages cannot send. It could sit in bezzle-web's `public/`,
for example at `/bezzle-web/app/`. What does not fit there: Apple's fonts (designs set in SF Pro
need another answer before a public version), and threads for drawing tiles in parallel (they
need those headers, or a service worker that adds them). The invitation page, open.html, is the
way in: without Bezzle installed it can open the design in the browser instead. At about 22 MB a first visit, GitHub Pages' soft limit of 100 GB a month
is some 4,500 first visits; a core on FoundationEssentials alone would be a fraction of that.
