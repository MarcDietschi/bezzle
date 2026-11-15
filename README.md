# Bezzle

A free design app for the Mac and for Windows: apps, websites, social posts and print, opening
Adobe XD, Figma, Sketch and Photoshop files. This repository holds the Mac app, the Windows app, the
browser viewer and the sharing relay. The website is a repository of its own (below).

Start here to find how anything is done. Each part has its own document; this page says which.

## What is where

| Path | What it is |
| --- | --- |
| `Bezzle/` | The Mac app (Swift, SwiftUI and AppKit). `Model/` is the design itself and is shared: the Windows app and the browser viewer compile it too. `Canvas/`, `Views/`, `Store/`, `Import/`, `Export/`, `MCP/` (the AI server), `App/` (launch, updates, `DebugHooks.swift`) |
| `BezzleTests/` | The Mac app's tests (Swift Testing), `ParityTests.swift` among them |
| `Windows/` | Bezzle for Windows: Swift with WinUI 3, built in a Windows VM on this Mac. `README.md`, `DESIGN.md` |
| `Web/` | The browser viewer (the model and renderer in WebAssembly, drawn with CanvasKit), published at bezzle.ch/app. `README.md` |
| `Relay/` | The Cloudflare relay that shared designs and live co-working go through. `README.md`, `SHARING.md` |
| `Packages/WebP/` | libwebp, vendored, for WebP export |
| `Packages/Vectorizer/` | Vectorize's engine: a picture traced into shapes, in plain Swift (the Mac app and Windows build it in). Its own tests and a command line that measures it. `README.md` |
| `Packages/Shaders/` | Shader fills' engine: a website's WebGL GLSL turned into Metal on the Mac and Direct3D 11 on Windows (glslang and SPIRV-Cross, vendored) and a recorded WebGL frame drawn into a picture or a texture. Its own tests. `README.md` |
| `Scripts/release.sh` | The Mac release. `Scripts/release-windows.sh`: the Windows release. `Scripts/release/`: the notes parser and the Windows feed writer |
| `Scripts/subject-matte/` | Makes Remove Background's model (git-ignored, too large for git) for the Mac and for Windows. `README.md` |
| `RELEASE_NOTES.md` | Every version's notes in English, German, French and Italian; the releases read them |
| `TODO.md` | What is known to be left: missing, unfinished or unchecked, by area |
| `AppStore/screenshots-src/` | Sources of the website's screenshots (the App Store version itself is gone) |
| `~/Sites/bezzle-web` | The website, bezzle.ch: its own repository, mfrports/bezzle-web, with its own `README.md` and `CLAUDE.md` |

## The processes, and where each is written down

| To | Read |
| --- | --- |
| Release a version (Mac, then Windows) | `CLAUDE.md` › Releases |
| Build, run and test the Mac app | below |
| Prove a change to shared code leaves the Mac as it was | below, Mac parity |
| Work on 3D: the scene, its eye, pushing layers in depth | below, 3D |
| Build, test and ship Bezzle for Windows; work in the VM | `Windows/README.md` |
| Change the website, the download page, the admin area | `~/Sites/bezzle-web/README.md` |
| Deploy or test the sharing relay | `Relay/README.md` |
| Publish the browser viewer | `Web/README.md` › Hosting |
| Make Remove Background's model | `Scripts/subject-matte/README.md` |
| Work on Vectorize's engine, and measure it | `Packages/Vectorizer/README.md` |
| Work on the shader engine, measure it, update glslang or SPIRV-Cross | `Packages/Shaders/README.md` |
| Test the Mac updater without a release | `CLAUDE.md` › Testing the updater |
| Withdraw a released version | `CLAUDE.md` › Withdrawing a version |

## The Mac app

Xcode, with its developer directory named, since this Mac's default is the Command Line Tools:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Bezzle.xcodeproj \
  -scheme Bezzle -destination 'platform=macOS' -derivedDataPath <scratch>/dd -resultBundlePath <scratch>/t.xcresult -quiet
```

- **Remove Background's model**, `Bezzle/Canvas/BiRefNet.mlpackage`, is git-ignored: a fresh clone
  makes it once with `Scripts/subject-matte/make.sh` (the release takes it from the working tree).
- **Reading a failure:** Swift Testing's details are not in xcodebuild's output; read them with
  `xcrun xcresulttool get test-results tests --path <t.xcresult>` (with the same `DEVELOPER_DIR`).
  When every test says "Crash: Bezzle", one test trapped: the newest
  `~/Library/Logs/DiagnosticReports/Bezzle-*.ips` has the real frame. A parameterized test is run by
  its suite (`-only-testing:Suite`); naming the test alone silently runs nothing.
- **On a busy Mac** (the Windows VM building, a release running) add `-parallel-testing-enabled NO`,
  which runs one test at a time: about 9 minutes instead of 2. Run together, the tests on the main
  thread wait for one another, a test's time limit counts its waiting, and when one runs out the
  whole run ends there: "Test exceeded execution time allowance", a hundred tests counted of 1,300
  and the rest never run (`readsAPageIntoBoxesAndWords`, three times on 2026-11-10 beside a VM
  build, and nothing wrong with it). When a time limit is the only failure, run them one at a time
  before looking for a fault. Since 1.8 the full run in parallel fails even on a quiet Mac:
  `FilmSharpTests.withTheViewCloseOnlyWhatIsInTheViewIsDrawnSharper` waits more than its minute
  for the stage's pictures, which queue behind every other test's (2026-11-15, on 1.8.1's commit
  as well). Run the whole suite with `-parallel-testing-enabled NO`.
- **Debug and Release:** Debug is not sandboxed and keeps designs in `~/Documents/Bezzle`; Release is
  sandboxed and keeps them in `~/Library/Containers/com.erik.Bezzle/Data/Documents/Bezzle`, which is
  where Erik's own designs are. When designs seem missing, look in both. Test anything that reaches
  files outside the library with a Release build.
- **Test copies** never use Erik's designs or his window: launch them in the background with their own
  library, `open -g -n --env BEZZLE_LIBRARY=<scratch> --env BEZZLE_MCP_PORT=<free port> <Bezzle.app>`.
  While Erik's Bezzle runs, give the copy a bundle id of its own (PlistBuddy, then
  `codesign --force --deep --sign -`), and never one that shares `com.erik.Bezzle`'s container.
  Photograph a window without raising it: `screencapture -x -o -l <window id>`.
- **Driving a copy:** `Bezzle/App/DebugHooks.swift` lists every `BEZZLE_…` switch at its top: open a
  design, select, pick a tool, click and drag on the canvas, open a card or menu, take snapshots, play a
  prototype. The AI server (`Bezzle/MCP`, on 127.0.0.1:7412, or `BEZZLE_MCP_PORT`) drives a running copy
  like a person would.
- **Speed:** Debug builds mislead. Build with `SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule`
  and run `BEZZLE_STRESS` (see DebugHooks). Erik's main screen is 5120×1440 at 1× and 75 Hz, so a
  frame has 13.3 ms; he runs both the released copy and Xcode's Debug build, so measure both.
- **Moving about quickly** (measured 2026-11-15 on a copy of Lawsearch AI, 17 artboards and about
  10,000 layers): `BEZZLE_FILM='4:zoom=fit;5:roam=40,16,8,1,40'` pans 40 points a frame while
  pinching from the whole design to 40 % and back, once a second each way (`pan=` pans alone,
  `zoom=` and `see=` set the view first; `AnimateHooks` has them), in step with the screen's frames,
  and writes to `BEZZLE_SCRUB_OUT` how many steps came late, how often the canvas was drawn and
  how long the main thread worked for each step. Launch the copy with its own bundle id, at the
  size of Erik's window (`BEZZLE_WINDOW=5120x1400`), and compare two builds back to back. Before
  2026-11-15 that roam came late about 100 times in 8 s in Design and in Animate; after, 1 to 10
  times (Debug: 71 and 116 before, 4 to 8 after). What made the difference, and what keeps it so:
  - No SwiftUI view reads what changes at every step of moving about: `store.viewport`,
    `visibleCanvasRect`, `focusedArtboard`. One that did had SwiftUI go over the whole window for
    every step, half of what a step cost. The bar's percent is drawn by AppKit and follows the zoom
    by itself (`ZoomPercent` in `Workspace.swift`); SwiftUI hears only `zoomDigits`, the room it
    takes, three digits from the whole design to 999 %. Even a change of the bar's width once a
    tenth of a second made a frame in four late.
  - The canvas is marked for drawing there and then when something it shows changes on the main
    thread (`CanvasView.draw`'s observation), and tiles and pictures that arrive while the view
    moves wait for its next step (`redrawForArrivals`): a second drawing within one frame waits
    for the screen, and the step after it comes a frame late.
  - Tiles are kept in the screen's colours and byte order (`Renderer.onScreen`), turned once where
    they are made. Kept in sRGB, every tile in sight was turned into the screen's colours again at
    every frame on the queue the window's drawing waits for. Shrunk artboards far out are a touch
    crisper since; everything else is within 2 levels of 255.
  - The film's stage keeps how large each piece ever shows in the film until the design changes,
    and under a pinch (three changes of zoom within 0.15 s) leaves its pictures stretched until the
    zoom stays put, as the tiles do.
  - A change of where the design is looked at alone is written after 30 s of rest, or with the next
    change, or on closing, not 2 s after each pause: the whole `document.json` (8 MB for Lawsearch
    AI) was written each time, 2 GB in an afternoon of looking about.

### Animate

The fourth way of seeing a design, beside Design, Prototype and Inspect: layers and a camera posed
along one artboard's film. Its keys are changes from the design and never the design.

- **Where:** the data is `Bezzle/Model/Motion.swift` and `Film.swift` (shared: Windows has Animate,
  `Windows/README.md`, and the browser viewer plays a film, `Web/README.md` › Films); everything
  the panel, the timeline and the menus do is a function of the store,
  `Bezzle/Store/AnimateOperations.swift`; the pointer's part is
  `Bezzle/Canvas/MotionTool.swift` on the canvas and `Bezzle/Views/FilmHand.swift` on the timeline,
  both plain classes so that tests can press and drag; `FilmStage.swift` draws, `FilmExport.swift`
  saves a movie, `MCPAnimate.swift` is the AI server's part.
- **Its tests** are the suites named `Motion…`, `Animate…` and `Film…`. Run them after any change
  to it, each named with `-only-testing:BezzleTests/<Suite>`.
- **Runs at random:** `AnimateStressTests` plays seeded sessions of several hundred steps, with
  undo and redo among them, and checks the film after every step. Put
  `TEST_RUNNER_ANIMATE_RUNS=800` before `xcodebuild test` for 800 more seeds (about 3 minutes),
  `TEST_RUNNER_ANIMATE_RUN=<seed>` to follow one, and `TEST_RUNNER_ANIMATE_DEEP=<every>,<from>` to
  undo and redo the whole session every so many steps. `TEST_RUNNER_ANIMATE_FILM_TIMING=1` also
  times the writing of a three second movie of each kind, and the memory it takes, into
  `$TMPDIR/bezzle-film-timing.txt` (2026-11-14, M5 Pro: 1.5 s either kind, some 700 MB), and
  `TEST_RUNNER_ANIMATE_FILM_DESIGN=<a design>` plays that design's own film on the stage in real
  time and writes what a frame costs and how sharp it shows into `$TMPDIR/bezzle-film-stage.txt`
  (give it a copy, never one of Erik's designs). A switch for tests never begins with `BEZZLE_`:
  the tests run inside the app, where such a name sets off DebugHooks.
- **How the film is drawn:** each piece (the artboard's sheet, a run of layers that stand still, a
  layer that moves) is a picture drawn once, which the graphics card then only moves
  (`FilmPictures`, `FilmPlacement`). Two rules keep it true to the design, on the stage and in the
  movie alike, and `FilmSharpTests` holds them. Sharp however near: where a piece shows larger
  than its picture holds, the part of it that is seen is drawn again as sharp as it is seen and
  laid over the picture (`FilmMap.seen`, `FilmPictures.Part`; on the stage in a layer named
  `part`, drawn ahead while the film plays). Nothing but the sheet ends at the artboard's edge:
  a shadow or a layer that reaches past it shows once the camera sees past it. A picture covers
  the artboard and some way round it (`FilmPictures.core`), the rest is drawn as parts when seen.
  A piece whose insides move (a moving shader, a shape or a look that is keyed, a masked or faded
  group holding a layer that moves) is drawn again at every moment, so it is drawn only as it
  shows then: the part seen through the film's frame, as sharp as it is seen
  (`FilmStageView.seenPart`). The stage draws its pictures in the screen's own colour space: in
  sRGB, Core Animation matched every colour of each new picture again on the main thread, which
  was most of a scrub's time on a screen that is not sRGB.
- **Gentle tones in a movie:** a wide dark gradient, a soft shadow, a blur or a slow fade shows
  as bands where its values are cut to whole steps, and as wider, uneven ones when they are cut
  twice. So a movie's are cut once. A piece that has such tones (`Node.hasGentleTones`: a
  gradient, a shadow, a blur, a shader) is drawn for the movie with sixteen bits to a colour
  (`FilmPictures.picture(deep:)`, `Renderer.Options.deep`; the stage's pictures keep eight).
  Not a piece that holds a blend which comes out otherwise there, Plus Lighter and Plus Darker,
  Color Dodge and Color Burn, or the four that take hue, saturation or lightness
  (`BlendMode.mixesDeepAsPlain`), nor a background blur made lighter or darker: Core Graphics
  counts in half floats there and stops at neither white nor black, so those keep eight bits
  and the canvas's colours (87 of a movie's 219 steps apart otherwise, in the test's patches).
  Core Image puts the frame together in half floats and writes it straight into the luma and
  chroma planes the movie packs (`FilmExport.Codec`), eight bits for H.264 and ten for HEVC.
  Handed over as BGRA, as it was, every value was rounded a second time by the packing. No
  noise is laid over the steps: what packs movies on a Mac irons fine noise out again unless
  the movie is many times larger (2026-11-14: kept only when let use sixteen times the bits,
  which made 25 Mbit/s of a movie that is 0.13 without). H.264 stays what a movie is, and shows the steps eight bits
  have; the Film card's other choice, HEVC with 10 bits (the AI server's `codec`), has steps a
  quarter as large. `FilmBandingTests` measures all of this on a film of such tones, in steps
  of eight bits by which the mean of every 8 by 8 block is off, and writes the numbers into
  `$TMPDIR/bezzle-film-banding-….txt` (2026-11-14, on average: 0.35 before, 0.29 as H.264, which
  is what one rounding leaves, 0.07 as HEVC). `TEST_RUNNER_ANIMATE_BANDING_STILLS=1` also
  writes down what exported pictures and the stage's pictures hold,
  `TEST_RUNNER_ANIMATE_BANDING_NOISE=1` what packing leaves of fine noise laid over the steps
  (run it again when macOS packs movies another way: it is why none is laid),
  `TEST_RUNNER_ANIMATE_BANDING_KEEP=<a folder>` keeps the movies it makes there with the film
  as a design, `tones.bezzle`, and `TEST_RUNNER_ANIMATE_BANDING_MOVIE=<a file>` measures a
  movie of that film made elsewhere: on Windows, or a kept one after a video site packed it
  again.
- **The camera's focus** (depth of field; `Bezzle/Model/FilmFocus.swift`, shared). The camera has
  two more numbers, keyed like its others in the artboard's tracks `cameraFocus` and `cameraBlur`.
  Blur is how much: so many points of blur for every hundred points a thing stands off the
  focus, counted in the artboard's points before the camera shows the thing larger or smaller,
  so a card a hundred points off under a Blur of 4 is blurred as its own Blur of 4 would blur
  it. Nothing, as designed, blurs nothing. Focus is what is sharp: so many points nearer the eye
  than the point of the sheet the camera looks at, along its line of sight (`FilmLens.nearness`).
  So a camera at rest is sharp on the page, one that comes closer stays sharp on what it looks
  at, a layer lifted 120 under a camera that looks straight down stands at 120, and under a
  camera tipped back the sheet's foot is nearer and its top further. A flat thing the camera
  does not face is therefore sharp along a line and softer away from it both ways, and in the
  frame that is a plain ramp: `FilmSoft`, three numbers that `Node.placement` gives every piece
  (`FilmPlacement.soft`; nil under a camera that blurs nothing, where a film is drawn as it
  always was). No blur goes past `FilmSoft.most`, 200 points, as far as a layer's own goes.
  One composer puts a frame together for the movie, a single frame and the stage
  (`FilmExport.composed`). Pieces that follow one another and lie in one plane
  (`FilmSoft.matches`) are laid together first and blurred as the one picture they are, so the
  page shows no seam where it is several pieces; a piece is blurred as if it went on past the
  frame's edge as it is there, and only where it shows and as far round that as its blur
  carries it (`reach`), not all over the frame. The ramp is Core Image's masked variable blur,
  which stops near 49 pixels however much is asked, so past 40 the same is done to a picture a
  quarter the size and mixed in between 20 and 40 (`varied`), which holds at any size of frame.
  It is worked out in half floats from the pieces' pictures and cut once with the frame, so a
  movie's blurred edges are as gentle as its other tones without a piece being drawn deep for
  it. Core Animation blurs a layer by one amount and by no ramp, so while anything that shows is blurred
  by half a pixel or more, the stage shows the frame through a lens (`FilmStageView.focus`, its
  layer named `lens`): the same composer, fed the stage's own pictures and parts, off the main
  thread into a surface in the screen's colours, only the part the view shows, one frame at a
  time with the newest moment winning. The pieces' own layers stay placed as ever under it,
  hidden while it shows, so nothing on the main thread waits for a frame of it: under a quick
  hand the lens shows the last frame it made, a frame behind the handles. Once nothing is
  blurred the lens is gone and the layers show again.
  In the app the Camera card has Focus and Blur under its other numbers and its pad dots the
  line along which the sheet lies in focus; with layers picked, in a film where anything stands
  off the page or the camera looks at an angle (`Node.filmHasDepth`), a card under Fly the
  Camera Here keys the focus at the playhead to where they stand (`DocumentStore.focusCamera`,
  `Node.focus(on:at:pieces:)`), and a camera that never blurred gets `FilmCamera.usualBlur` as
  one key, which holds for the whole film, so that from one such key to the next the focus
  alone is pulled. See the Whole Artboard leaves both (`MotionProperty.view`). An assistant
  sets `cameraBlur` and `cameraFocus`, or a camera key with `focusOn`, the layers it is sharp
  on then. Bezzle 1.7 knows neither track: it keeps them, in the file and shared, and shows the
  film without the blur. Its tests are `FilmFocusTests` (the arithmetic, by hand),
  `FilmFocusFrameTests` (frames measured by how far an edge is spread, the stage against the
  frame, the movie), `FilmFocusKeysTests` (keys, the file, sharing, an older Bezzle, the store)
  and `FilmFocusMCPTests`. `TEST_RUNNER_ANIMATE_FOCUS_PICTURES=<a folder>` writes frames of
  such films there to look at, and `TEST_RUNNER_ANIMATE_FOCUS_DESIGN=<a folder>` the film the
  scrub was measured with, once without a lens and once with one: 1440 by 900, twenty cards of
  which fifteen stand off the page at three heights, under a camera that zooms, tips and swings.
  Measured on 2026-11-14 (M5 Pro, a screen of one pixel to the point at 75 a second, other work
  going on beside) in optimized copies with a window of 3400 by 1300, the playhead dragged 120
  times a second: without a lens this copy kept 120.0 steps a second in nine scrubs of nine with
  no gap over 15 ms, as the copy from before the lens did in three of its six (113.6 to 119.6 in
  the three made beside a heavier load). With a lens it is 119.1 to 120.0 steps a second in ten scrubs
  of twelve (115.7 and 118.1 in the other two, with gaps of 40 and 27 ms), and the lens makes 67 to
  95 frames a second at 10 to 13 ms each, and 72 of the screen's 75 while the film plays. A lens
  frame costs about a millisecond for every plane that is blurred by itself, whatever its size
  (the variable blur), and the page's pixels: the same film at two pixels to the point takes 20
  to 22 ms a frame in the test host (`TEST_RUNNER_ANIMATE_FOCUS_TIMES=<a design>`, which times
  the composer alone; `TEST_RUNNER_ANIMATE_FILM_DESIGN` says what the lens made on the stage),
  and no screen of that kind has shown it yet.
- **Keeping it quick:** what is placed at every frame is found once (`Node.filmLayers`, not a
  search through the artboard per piece); new pictures are placed on the stage without drawing
  the canvas again; what is watched by views (`film.playing`, the timeline's hand) is set only
  when it changes, and the timeline's header, which depends on the playhead, is a view of its own
  so that a scrub does not build every line again. The panel's cards show `store.panelTime`, the
  playhead caught up with at most thirty times a second while it is dragged (a step alone at once,
  the last of a drag always); the film, the playhead and its clock follow every step. The picked
  layer's way and its home outline are kept until the design changes (`MotionTool`), since they
  do not depend on the playhead. To measure, `BEZZLE_FILM=…;4:scrub=0,10,8`
  with `BEZZLE_SCRUB_OUT=<file>` drags the playhead through a film 120 times a second and writes
  how many steps the app kept up with; run it on an optimized copy (see Speed, above) of a copy
  of a real design, and `sample <pid>` meanwhile. Under a camera that blurs, the line ends with
  what the stage's lens made: how many frames, how many a second, and how long each took. Launch
  the copy with `--args -ApplePersistenceIgnoreState YES`: a copy that was stopped by a signal
  otherwise comes up without a window the next time, runs no hook and writes nothing.
- **The timeline looked at closer:** which part of the film shows is `store.film.window`, the
  viewer's own and no part of the design (nil is the whole film, and each film is seen whole
  first). Where a moment lies is `FilmScale` with its `start`, and looking closer, moving along
  and the limits are its plain functions beside `FilmWindow` in `Bezzle/Model/FilmKeys.swift`
  (shared, for Windows to use): no closer than `FilmWindow.closest` points a second, where a
  hundredth of a second is a dozen points, and no further out than the whole film, where a
  pinch catches. `FilmHand` holds what the hand does (`zoom`, `scroll`, `smartZoom`, and `creep`,
  which moves the sheet along under a playhead, a key or a marquee dragged past its end);
  `Bezzle/Views/FilmFingers.swift` hears the pinch, the double tap with two fingers and the wheel
  for it, through one monitor of the app's events, since SwiftUI tells of no scrolling: a pinch
  or two fingers that begin over the lines are the timeline's until lifted, sideways moves it
  along, up and down stays the lines' own scrolling, and Command, Option or Control with the
  wheel looks closer as on the canvas. The playhead is kept in sight by the store: `seek` brings
  the part along (not under a hand on the playhead, which creeps instead), and a film playing
  out of it turns the page, so the window changes once a page and never at every frame. The
  ruler (`FilmRuler.step`, `strokes`) draws only the strokes in sight. Its tests are
  `FilmZoomTests`.
- **A marquee over keys:** on the timeline's sheet the ruler moves the playhead, and so does the
  playhead's own line down the sheet, taken within `FilmHand.headReach`. A bead, a bar and the
  film's end are taken as before. Bare sheet clicked puts the playhead there and lets go of the
  picked keys (with Shift it changes nothing); bare sheet dragged three points or more draws a
  rectangle that picks the keys it touches as it grows, with their layers or the camera, since
  keys are only ever picked of what is picked. With Shift it picks what it catches that was not
  picked and lets go of what was. The rectangle is kept in moments and in points down the lines
  (`FilmMarquee`, with what it catches, in `Bezzle/Model/FilmKeys.swift`, shared, for Windows to
  use), so it keeps what it caught where the sheet creeps along under it. In a film of more
  than seven lines it scrolls them the same way when it is drawn past the top or the foot of
  those in sight (`FilmHand.climb`), reaching no further than the lines show and catching what
  comes into sight. The card tells the hand how far down its lines are scrolled (`linesTop`, from
  `onScrollGeometryChange`), and the hand scrolls them through a `ScrollPosition` of the card's
  own, which no other view reads. Its tests are `FilmMarqueeTests`.
- **Escape under every drag** on the timeline, a key, several, a line's band, the playhead, the
  film's end or a marquee: everything is as it was before the press came (`FilmHand.cancel`).
  The keys' moments and the film's length go back by `cancelGesture`, which leaves nothing to
  undo; what was picked, the playhead (where it showed, of a film that played), the part of the
  film the sheet showed and how far down the lines it was scrolled are put back by the hand.
  The hand asks the keyboard whether Escape is down (`heed`: at every step of the drag and sixty
  times a second while anything is in hand), because the app is told of no key while SwiftUI
  follows a press, neither its event monitors nor whatever has the keyboard, and Escape does not
  end SwiftUI's drag either (measured 2026-11-14 on macOS 27.2 in a test copy). Its tests are
  `FilmEscapeTests`.
- **Copying keys** (`Bezzle/Store/AnimateClipboard.swift`): while Animate has keys picked, Copy,
  Cut and Duplicate in the Edit menu, and their keys, are of those keys, and Paste puts keys
  copied down; with none picked, Copy and Duplicate are the layers' as ever, and Cut and Paste do
  nothing in Animate. Keys go onto a clipboard of the app's own (`DocumentStore.filmClip`), never
  the pasteboard nor a design, and stay there until other keys are copied, or layers. Paste puts
  the earliest on the playhead and the others as far from it, onto the layers and the properties
  they came from, each picked key standing for what its bead did (on a layer's line every key at
  that moment, on a property's line that one); the camera's onto the camera of the film on the
  desk. The keys of one layer alone go onto the layers picked when another is among them, each
  only where that layer can take it (`taken`: a Shape of as many points, a shader's input of as
  many numbers, a look the layer has as the key says). A key already at a moment gives way
  (`place`), the keys pasted are picked with their layers, and it is one step through `edit`, so
  a design shared live takes it key by key and an undo takes back only it. Duplicate puts copies
  half a second after the last key picked, as far apart as they are, and picks them. Option held
  as a bead or a band is pressed leaves the keys and drags copies of them
  (`retime(copying:)`), as Option does layers on the canvas; held once the press is under way it
  steps finer, as before. Its tests are `FilmKeyCopyTests`.
- **A shader fill that builds on its frames** (feedback, trails, a simulation:
  `ShaderFill.builds`) shows at a film's moment the step that moment falls in, drawn forward from
  what the page's textures held when it came in, by steps as often as the page drew (sixty a
  second, or its timer's rate), each with its inputs as they are at that step's own time. So the
  same moment is the same picture however the playhead got there. Playing draws one step a
  frame; going back draws at most 31 steps from a state the engine kept; a jump far forward draws
  every step between, once (`Packages/Shaders/README.md` › What Bezzle keeps of a page).
- **Shapes** (paths, and rectangles, ellipses and lines, whose outline is points too) have two
  properties more: Draw, how much of the outline is drawn as a pen draws it, one run after
  another, and Shape, its points and handles each moved from the design's, six numbers to a point
  in the layer's own upright points (`Bezzle/Model/PathMotion.swift`). A film draws a shape whose
  keys change it as a path (`Node.reshaped`), its frame grown to hold points that go past it, and
  turns and grows it about the design's middle still. Its
  points are changed in the film with the shared pen (`PenTool`) through `FilmPoints`, its host in
  Animate, which shows them where `Node.filmPointMap` puts them and poses the Shape at the
  playhead: moved, and added or taken away as in the design (a click on the outline, Delete), which
  changes the outline at the playhead alone and never the design's. Its tests are `MotionPathTests`
  and `AnimateCanvasPathTests`.
- **Shape keys go with the design's outline** when it changes, in one step with the change.
  Points added, taken away or dragged: each key with its point (`MotionTrack.realigned`, from
  `BezzleDocument.setPoints`). A layer resized: its keys grown as far as each side grew (Move's
  stay points on the artboard). A rectangle given other corners, or a path given other points
  by anything but `setPoints`: each new point goes as the place it lies at on the old outline went, so the film still shows
  what was keyed (`BezierPath.Following`, `Node.shapeKeys(following:)`). A rectangle's corners
  changed in the same frame go by way of its square: a key that is what the square's keys
  followed to its corners would be, as every key made while it was square is, is taken back to
  those exactly (`BezierPath.Following.source(of:)`, least squares, kept only where it gives the
  key back to a millionth) and followed on from there (`MotionTrack.following(_:to:through:inOrder:)`).
  So corners rounded, rounded otherwise, smoothed and squared again give back every number that was
  keyed, where they gave back about 47 points of 50; a key made on the rounded rectangle itself goes
  as before, each corner as the place on the curve nearest it went. Both come from
  `BezzleDocument.followOutlines(since:start:)`, which `DocumentStore.edit` calls after the other
  passes: it looks at every layer whose outline the change made another and whose keys it left
  alone, so a new way of changing an outline needs nothing more, and each cell of a repeat grid,
  post of a deck and copy of a component keeps its own keys with its own outline. Flipped, a
  layer's keys are turned over with it (`Node.shapeKeysFlipped`, from `BezzleDocument.flip`: a
  flip of an ellipse leaves its outline as it was, so only the flip itself can tell). Keys that
  fit no outline change nothing. Its tests are `MotionOutlineTests`, and `AnimateStressTests`
  resizes, rounds and flips layers under its films.
- **One outline into another with other points** (a star into a circle) is `BezierPath.matched`
  and `mixed`, in `PathMotion.swift`: both are given the same points, neither changing its shape.
  An anchor both have in one place is one anchor; between such anchors each lies as far along its
  stretch as it does, two that come to lie close are one, and any other gets a point on the other
  outline there. Outlines that share no anchor are laid along each other whole, begun where and
  run the way their points go least far; a run with none to go with shrinks to its middle. Outlines
  with the same runs of as many points go point by point as they are numbered, so an outline taken
  from another shape is first numbered like the one it comes from (`numbered(along:)`, its own
  points begun and drawn as they lie along it; `laid(along:)` gives it the points more that
  `matched` would as well). `goesAlong(into:)` says whether a stretch goes as two outlines lie
  along each other, which point by point it may not. Its tests are `MotionMatchingTests`. A film asks for it between two keys that say other points
  (`MotionTrack.outline(at:from:)`), and keeps the pairs it was given lately (`MatchedOutlines`).
- **A key with an outline of its own** is what a Shape key is where it says other points than the
  design's, more or fewer, or runs open where the design's are closed. It comes of points added or
  taken away at the playhead, and of another shape's outline taken (the Pose card's From… chip,
  `DocumentStore.takeShape`). An assistant gives one as a `path` with other points, or as
  `outlineOf`, another shape (`animate`). Its numbers are in the `v` every key has: a nought for
  each number a change of the design's points would have; then each run as six numbers (how many
  anchors, closed or not, four kept for later) and six for each anchor, where it and its handles are
  in the layer's own points; and last, how many sixes the runs take. So it has one number more than
  a whole number of sixes, which a change never has, and is read from its end (`BezierPath.asKey`,
  `BezierPath.init(key:)`). Bezzle 1.7 reads as many numbers as the design's points have, the
  noughts: it shows the design at such a key, goes to it and from it gently, and keeps the key as it
  is. At a key the outline is exactly the key's; between two that say the same runs every point goes
  its own way, paced and flown like any property's; between two that say other points the one goes
  into the other by `matched`, at the pace chosen or gently (`MotionTrack.shapePace`).
  `Node.shapeValue(of:)` says an outline as a change where it can and as itself where it cannot, and
  `Node.kept` brings numbers made for another layer to this one's. When the design's outline
  changes, such a key keeps its outline where it shows: grown with a resize, turned over with a
  flip, shifted when `setPoints` fits the frame anew (`MotionTrack.withOutlines`). Another shape's
  outline is placed for a layer by `Node.outline(of:for:at:)`, as large and turned as the other is
  on the artboard and about the layer's own middle, and kept by `Node.shapeValue(taking:at:)` with
  its own points and no more, numbered to come from the key before or else to go into the key
  after, so the points taken in hand at that key are the other's own. Only where a key either side
  has the same runs and would go into it point by point otherwise than the two lie along each other
  (a square and a circle of four points each, whose corners would go round) does it keep the points
  more that lay it along the key before. Measured on 2026-11-15 on eleven pairs, among them a
  triangle into a rectangle, a rectangle into a circle, a star into a rounded rectangle, open into
  closed and back: the film is the same at every moment as with those points more, but for a
  rectangle after a triangle, which now opens out of it evenly with five points on the way, not
  six. `Node.shapesToTake` lists whose a layer can take. Its tests
  are `MotionOutlineKeyTests`, and `AnimateStressTests` keys other outlines and takes them from
  other shapes.
- **Looks** (`Bezzle/Model/LookMotion.swift`, shared): a layer's fills, borders and shadows and a
  rectangle's corners are keyed too, in tracks named for what they change (`LookTrack`: `fill.0`,
  `fill.0.stops`, `border.0`, `border.0.stops`, `border.0.width`, `shadow.0`, `corners`; the
  number is the slot, counted from the bottom, and the keys follow their fill, border or shadow
  when it is restacked or taken away). A key holds a change from the design. For a colour that is
  a colour laid over the design's by an amount (five numbers in OKLab, all nothing where the
  design shows), so a design restyled, a named colour changed or an artboard turned dark is what
  the film starts from, while a colour that was chosen stays the chosen one; for a width, a
  corner, a shadow's place and blur and a gradient colour's place it is how far from the design's.
  `Node.looked(at:)` is the layer as it looks at a moment, and `Node.posed(at:)` calls it, so the
  stage, the movie and the single frame draw it. Keys made for what the design no longer has (a
  fill taken away, one colour made a gradient, a gradient with other colours) change nothing,
  wait for it to come back and show faint in the timeline (`Node.fits`, `FilmRow.Mark.gone`). So
  do the Corners keys of a rectangle whose Shape has keys: those move the points the design's
  corners make, so there the corners stay the design's (`Node.lookCount`). In
  the app the design's own cards do it: the Animate panel shows them under Pose for the picked
  layers as they look at the playhead (`SelectionInspector(filming:)`, `store.lookedSelection`),
  and `DocumentStore.updateSelection` hands a change made in Animate to `poseLooks`, which keys
  what it changed of the looks and drops the rest; a change to no look is the design's as before.
  Where such a change changed how a layer looks (dashes taken off, a fill turned off), the card of
  that look says "Changed in the design" for a moment in place of its summary
  (`DocumentStore.designLooked`, `SelectionInspector.toldDesign`, `AspectCard`'s `note`).
  What cannot be keyed (a picture, a shader, on and off, dashes, a border's side, which side a
  shadow falls on, a gradient's line) is not on the cards there. A rectangle's corner dots are on
  the stage (`MotionTool.cornerDots`). Its tests are `MotionLooksTests` for the arithmetic and
  `AnimateLooksTests` for the cards, the timeline, the stage and the AI server.
- **Shared with others**, a film goes setting by setting (`film/length`, `film/once`,
  `film/backdrop`) and a layer's motion key by key (`motion/<property>/<thousandths>`, with
  `/given` for a key the app placed itself; a look's by its track's name, `motion/fill.0/1000`),
  so two people keying one layer both keep theirs (`Bezzle/Model/FlatDesign.swift`). Keys closer
  than a frame's quarter are one: `BezzleDocument.repairMotion()`.
- **Driving a copy:** `BEZZLE_ANIMATE` and `BEZZLE_FILM` (`Bezzle/App/AnimateHooks.swift`) pick,
  pose, play, press and scrub. Their clock starts when the hook does, well after launch: photograph late.
  `pinch=`, `tap2=`, `wheel=` and `swipe=` send the timeline the events a trackpad or a wheel
  would, through the app's own queue, and `timeline` writes which part of the film shows into
  `BEZZLE_SCRUB_OUT`: the way to see the gestures arrive without a hand on a trackpad.
  `press=` goes through that queue too and reaches the canvas, the panels and SwiftUI's buttons,
  taps and drags alike, the timeline's among them, in a copy that stays in the background. Of a
  click on a window that is not the one in front, AppKit first asks the view under it whether
  it takes such a click, and SwiftUI says yes for a button and no where it waits for a tap or
  a drag, so the hook has that view's kind say yes while the press lasts (`takesFirstClick`).
  `+` before the points keeps the button down until `lift=`, `escape=1` stands in for Escape
  held down, and `picked` writes what is picked into `BEZZLE_SCRUB_OUT`.
- **Its words** are in the catalog in all four languages; `AnimateWordsTests` fails when one is
  missing, so a new property, look, pace or move brings its words along.

### 3D

An artboard is one 3D scene. Everything on it that is turned, brought nearer or pushed away is
seen from one eye in front of the artboard's middle, as far above it as Animate's camera rests
(`Eye.stage`, twice the larger side and never under 600 points). So layers share one vanishing
point, a layer brought nearer grows and comes out from the middle, and what is nearer covers what
is further whatever the layers list says (layers as near as each other keep the list's order). A
group is one card in the scene and orders what it holds inside itself, unless it is told to keep
its layers' depth (below). Off any artboard a layer is
seen from in front of its own middle, as before. The artboard's own sheet is the scene's backdrop:
what is pushed behind the page still shows on it, as CSS paints a parent's background first.
Animate's camera at rest sees what the design shows; tilted or swung, it sees how high each layer
stands, and the sheet still lies under everything.

Several layers picked that lie together (on one artboard, or in one group on it) turn as one body:
about the middle of the box round them, each ending where a real body's face would, moved, higher
or lower, and facing another way. The body is read and led by its largest face, its lead: the 3D
card shows the lead's numbers, X and Y turn the body with it, Z lifts the whole body by as much as
the lead goes, and Lay Flat lays a body turned from flat back to the point where it lay. Nothing
of the body is stored: each layer keeps where it stands and how it is turned, as before. Off any
artboard, or one layer in each of several parents, each turns about its own middle. In Animate the
Pose card's Tilt and Swing key several lying together as one body at the playhead (tilt, swing,
and move, lift and turn where they change), and so does the canvas: picked together, they show
one set of handles round the body, the box round them in the plane of the lead's face as they
stand at the playhead (`FilmBody`, shared). From beside a side it tips and swings the body as the
card does (`poseInDepth`), from just outside a corner it turns it in that plane about the box's
middle, and by a corner or a side it grows it about that middle, evenly or one way along the
lead's sides (`BezzleDocument.poseBody`); each drag is one step, measured from the design as it
began. Between keys each property goes its own way, so a group is what keeps layers one thing
throughout. The AI server's `turn_layers` does both.

What is nearer covers what is further by the height of each layer's middle, with one exception
that a body needs: layers turned to face the same way, with their middles at different heights,
that lie in one plane or over one another are ordered as parallel faces cover one another, by how
far each plane lies in front, and those in one plane as listed (`DepthOrder.nearness`; the film's
`filmOrder` uses the same). So a button stays on its card when both are swung, though its middle
then stands lower than the card's, and a title in the card's middle, its middle exactly as high
as the card's, stays on the card when something held over the card's higher end raises it.

An artboard can be looked at from the side while designing, to see how high each layer stands.
The page is not turned: the eye is moved aside (`DepthLook`, at most 60°), as someone moves their
head in front of a window. So the page and all that lies flat in it stay where they are and every
tool stays true, while what stands off the page shows where the moved eye sees it, with a post
under each corner straight down to the page, which every height is measured from (under what is
picked alone, when some of it is; under each layer of a group that keeps depth, which has no
card of its own). Where a nearer layer stands between the eye and a post, the post is hidden
there, as the posts under the far side of a card stand behind it (`BezzleDocument.shownParts`,
worked out once per change of the design, the look or what is picked; on Windows the posts are
still drawn whole). The word stands in the line the artboard's name is in, and over a
carousel's slide numbers in the line above (`LookTool.wordRect`). On
the Mac, Control dragged beside the layers turns the look (Shift in fives); a click there with
Control, Escape with nothing picked, or the word by the artboard's top right corner looks from the
front again (on Windows the key is Alt, `Windows/README.md` › The app). View › Look from the Side,
also in the zoom menu, begins it for the artboard being worked on, from the left and a little
above (`DocumentStore.firstLook`), and reads Look from the Front while any artboard is seen so;
it is off in a read-only design, while looking back at versions, and with no artboard. The menus
ask only `lookingAside`, which changes when looking begins or ends, never at each step of a drag.
It is a way of looking, never part of the design: `DocumentStore.looks` holds it and
hands it to the design it shows (`BezzleDocument.looks`, which no file has and `==` leaves out), so
everything on the canvas asks `doc.eye(…)` as ever and is given the moved eye. It is not an undo
step, and it ends when the design is seen as a prototype, inspected or animated. The renderer
sees from the side only where the canvas says so (`Renderer.Options.looks`): exports, films,
thumbnails and the AI server's pictures are always from the front.

A group can be told to keep its layers' depth (`Node.keepsDepth`, the 3D card's switch for a
group and Layers Keep Their Depth in its right-click menu, both `DocumentStore.keepDepth`, the
AI server's `keepsDepth`): CSS's `transform-style: preserve-3d`. What it holds then
stands in the artboard's scene layer by layer, where the group's turn and height put it, and is
ordered among everything beside the group, nearer over further across its border, instead of
being drawn onto one card that is then turned. As in CSS, anything done to the group as a whole
makes it one card all the same (`Node.opensInDepth`): a mask, a fade, a blur, a shadow, a blend,
and here also a repeat grid, pinned corners and a background blur lying directly in it. Off any
artboard there is no scene, and it is a card. How it works: the eye carries the space
(`Eye.space`, built by `Eye.within(group)`, which every walk down into a group now asks in place
of `inside(origin)`). Inside such a group a layer's `Perspective` stands it in the scene and
gives where it shows as the point lying in the group that shows at the same place, so the
group's own perspective, a card's, carries it on to the canvas as it carries everything else:
all that composes perspectives down a chain of parents (`doc.shown`, `doc.placed`, handles,
snapping) stays as it was, and a layer lying flat in the group still needs none.
What draws asks `Perspective.onCanvas`, which is where the layer shows itself. The order is
`DepthOrder.scene`: the layers lying together with every such group's layers standing in its
place, which the renderer (`Renderer.drawScene`), the picker (`Picking.topmost`), `Geometry.bounds`
and `contains`, `Renderer.reach`, and the hit test of the prototype player, Inspect and the flow
tool (`Prototype.chain`, which gives the layer, then the groups it was taken out of) all go
through; a click on such a layer takes its group, and inside the group the layer. SVG, which
cannot turn anything in depth, writes the same order (`SVGWriter.scene`): such a group goes out
whole where nothing beside it comes between its layers, as one picture when it is turned or held
up, and is split where something does, each part under the group's name, what it turns or holds
up as pictures (`Renderer.scenePicture`) and what lies in the page as it is. In a film, such a group with no keys of its own comes apart into
pieces that stand where it puts them (`FilmPiece.stand`), so the camera at rest shows what the
design does and sees between the layers when it moves; with keys of its own it is one card. The
layers lying in the group next to one another are one piece, and where the group is turned the
film asks about each of them as the design does (`FilmStand.lying`, made by the same
`DepthOrder.face`), so it draws the pieces in the design's order. A layer's keys there are
measured where its place is, in the group (`FilmStand.posed`): a Move slides it along the
group's plane, a Lift raises it along the way the group faces, a Tilt or a Swing is added to its
own turn inside the group, so the film shows at every moment what the same change shows made in
the design, and a layer lying in the group slides where the same keys slide it on a group that
is one card. The
flag is one optional key on a group, written only when set, and one more property shared on its
own (`LayerField`): a Bezzle that does not know it reads the same group as one card.

- **Where:** all shared with Windows and the browser. `Bezzle/Model/Perspective.swift` has `Eye`,
  the homography seen from it, and `BezzleDocument.eye(inside:)` and `eye(forParentOf:)`, where any
  layer is seen from. `DepthOrder.swift` is nearer over further, `DepthPushing.swift` the push
  while dragging, `DepthTurning.swift` the knob and turning from a side, `DepthBody.swift` several
  layers turned as one (`turnInDepth`, `layFlat`, `poseInDepth`), which the Mac's card and pad
  reach through `Store/DepthOperations.swift`, `DepthLooking.swift` the look from the side and
  its posts, which the Mac's canvas turns with `Canvas/LookTool.swift`. In a film,
  `FilmBody.swift` is several layers posed as one body on Animate's canvas and
  `FilmMovePlane.swift` the plane a dragged layer moves along, both reached through
  `Canvas/MotionTool.swift`. The renderer finds the eye itself, from `Options.board` and `offset`
  (`Renderer.Options.eye`).
- **The rule for new code:** whatever asks where a layer in depth shows (`Perspective`,
  `Geometry.bounds`, `Geometry.contains`, `Renderer.reach`, `Prototype.chain`) is given the eye of
  the layer's parent. Without one it sees the layer from its own middle, which is only right off
  artboards. Ask the design for an artboard's eye (`doc.stage(of:)`, `doc.eye(inside:)`), not
  `Eye.stage`, wherever the canvas is concerned, so a look from the side is seen; and read
  `doc.front` in anything that leaves the canvas, so it never is.
- **On the canvas:** Control held while moving layers pushes them away or pulls them nearer, up
  nearer by a point for a point, catching at the page and at the heights of the layers around,
  Shift in tens; pressed or let go during the drag, nothing jumps. The knob takes Control as it
  takes Option. A layer only held at a height and facing the eye has no knob, so a drag on its
  middle moves it. In Animate, Control while moving keys Lift. On Windows the key is Alt, pressed
  once the drag is under way (Alt at the press duplicates). In Animate a layer dragged stays under
  the pointer however high it stands and in a group turned in depth, keeping depth or one card:
  as the drag begins, the plane its Move slides it along is found as the film shows it
  (`Node.filmMovePlane`, shared: four Moves posed and shown, which settle the plane), and the
  pointer is cast onto it at each step (`MotionTool.travel`; Windows does not yet).
- **Its tests** are `DepthSceneTests`, `DepthTests`, `DepthBodyTests`, `DepthLookTests` and
  `DepthKeepTests`, with `MotionLensTests` for the film and `DepthFilmTests` for films of groups
  that keep depth, held against the design's own order and picture; `FilmBodyTests` and
  `FilmMovePlaneTests` for bodies and drags in a film, and on Animate's canvas
  `AnimateCanvasBodyTests.swift` and `AnimateCanvasDepthTests.swift` (in `AnimateCanvasTests`).
- **Driving a copy:** `BEZZLE_CLICKS` takes `^x,y>x,y` for a drag with Control held.

### Mac parity

`Bezzle/Model` is compiled into the Mac app, the Windows app and the browser viewer, so a change made
for Windows can change the Mac. Erik's rule (2026-11-07): share only logic that tests cover, copy
drawing and untested parts rather than share them, and commit Mac-touching work apart from Windows
work. To prove a move leaves the Mac unchanged:

- `BezzleTests/ParityTests.swift` drives the canvas tools through real events and writes each step to
  `$TMPDIR/bezzle-parity.txt`. Run it in a `git worktree` of the commit before the change (link the
  git-ignored `BiRefNet.mlpackage` in) and in the working tree, and `diff` the two logs. Add a scenario
  for every tool that becomes shared.
- For drawing, run both builds as test copies on the scene `ParityTests.writesTheScene()` writes and
  compare the canvas pixels.

## Working here

- **Git:** commits go straight onto `main`, made with a pathspec (other sessions may have staged their
  own files). Pushing is Erik's word; a release pushes as part of it.
- **iCloud Drive:** this folder is in `~/Documents`, which iCloud syncs. When git says
  `bad object refs/heads/main 2` (or any ref or file with " 2" in its name), iCloud left copies in
  `.git`: list them with `find .git -name '* [0-9]'`, move them out of `.git`, run
  `git fsck --connectivity-only`, and try again.
- **Words people read** (the app, the notes, the website): no dashes as punctuation and no
  exclamation marks, in any language; the app's own words come from `Localizable.xcstrings`.
