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
pictures and fonts as drawings ask for them. `?relay=` points it at another relay.

It edits, with `site/editor.mjs` on the page and `Web/WebEditing.swift` in the core: layers are
picked on the artboard (double-click goes into a group, or types into a text), dragged and resized
by their handles as one gesture, nudged with the arrow keys, deleted; a small inspector sets the
frame, fill, border, corners, opacity and type; the notes of the artboard or of a layer are read,
written, answered and closed. Every change goes through the steps the Mac's `DocumentStore.edit`
takes after one (grids, decks, components, styles, masks, notes, groups fitted), undo takes back
only what was done here (`FlatDesign.apply`), and a moment later it goes to the room as a record of
this browser's own, under the name asked once. Others' changes wait while something is dragged or
typed. `node tools/edit.mjs` tests the core's side on a sample, two copies at once.

Tested against the relay itself, running here (`cd ../Relay && npx wrangler dev --port 8790`):

| | Result |
|---|---|
| `node tools/link.mjs`: a design shared by one browser, opened from the link by another | the same design; edits both ways; 63 records folded to 40 with two wholes; a copy coming later has everything; pictures whole; nothing opens without the link; unsharing heard at once |
| `node tools/link.mjs --mac <file>` between the two halves of `CloudShareTests.forTheBrowser` (`TEST_RUNNER_BEZZLE_RELAY_TEST`, `TEST_RUNNER_BEZZLE_WEB_LINK=<file>`) | a design the Mac shared opens here as the Mac's to the byte; the browser's edit comes back to the Mac, merged the same |
| `node tools/room.mjs <design.bezzle> --edit`, then `shared.html?relay=http://127.0.0.1:8790#2.<secret>` in Chrome | the page shows the design live, with its pictures, and follows the edits |

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
co-working's pointers and presence (the page hears only that there are new records), drawing
new shapes, the icon
library (needs zlib), localization (four languages on the shared page, English elsewhere).

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
