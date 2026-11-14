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
  before looking for a fault.
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
  and run `BEZZLE_STRESS` (see DebugHooks); the display is 120 Hz, so a frame has 8.3 ms.

### Animate

The fourth way of seeing a design, beside Design, Prototype and Inspect: layers and a camera posed
along one artboard's film. Its keys are changes from the design and never the design.

- **Where:** the data is `Bezzle/Model/Motion.swift` and `Film.swift` (shared, so Windows and the
  browser keep a film they cannot show yet); everything the panel, the timeline and the menus do is
  a function of the store, `Bezzle/Store/AnimateOperations.swift`; the pointer's part is
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
  times the writing of a three second movie, into `$TMPDIR/bezzle-film-timing.txt`, and
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
  A piece whose insides move (a moving shader, a masked or faded group holding a layer that moves)
  is drawn again at every moment, so it is drawn only as it shows then: the part seen through the
  film's frame, as sharp as it is seen (`FilmStageView.seenPart`). The stage draws its pictures in
  the screen's own colour space: in sRGB, Core Animation matched every colour of each new picture
  again on the main thread, which was most of a scrub's time on a screen that is not sRGB.
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
  of a real design, and `sample <pid>` meanwhile.
- **The timeline looked at closer:** which part of the film shows is `store.film.window`, the
  viewer's own and no part of the design (nil is the whole film, and each film is seen whole
  first). Where a moment lies is `FilmScale` with its `start`, and looking closer, moving along
  and the limits are its plain functions beside `FilmWindow` in `Bezzle/Model/FilmKeys.swift`
  (shared, for Windows to use): no closer than `FilmWindow.closest` points a second, where a
  hundredth of a second is a dozen points, and no further out than the whole film, where a
  pinch catches. `FilmHand` holds what the hand does (`zoom`, `scroll`, `smartZoom`, and `creep`,
  which moves the sheet along under a playhead or a key dragged past its end);
  `Bezzle/Views/FilmFingers.swift` hears the pinch, the double tap with two fingers and the wheel
  for it, through one monitor of the app's events, since SwiftUI tells of no scrolling: a pinch
  or two fingers that begin over the lines are the timeline's until lifted, sideways moves it
  along, up and down stays the lines' own scrolling, and Command, Option or Control with the
  wheel looks closer as on the canvas. The playhead is kept in sight by the store: `seek` brings
  the part along (not under a hand on the playhead, which creeps instead), and a film playing
  out of it turns the page, so the window changes once a page and never at every frame. The
  ruler (`FilmRuler.step`, `strokes`) draws only the strokes in sight. Its tests are
  `FilmZoomTests`.
- **Shapes** (paths, and rectangles, ellipses and lines, whose outline is points too) have two
  properties more: Draw, how much of the outline is drawn as a pen draws it, one run after
  another, and Shape, its points and handles each moved from the design's, six numbers to a point
  in the layer's own upright points (`Bezzle/Model/PathMotion.swift`). A film draws a shape whose
  keys change it as a path (`Node.reshaped`), its frame grown to hold points that go past it, and
  turns and grows it about the design's middle still. Shape keys go with their points when the
  design's points are added, taken away or dragged (`MotionTrack.realigned`, from
  `BezzleDocument.setPoints`); keys made for an outline with other points change nothing. Its
  points are moved in the film with the shared pen (`PenTool`) through `FilmPoints`, its host in
  Animate, which shows them where `Node.filmPointMap` puts them and poses the Shape at the
  playhead; there points are only moved (`PenHost.pointsFixed`). Its tests are `MotionPathTests`.
- **Shared with others**, a film goes setting by setting (`film/length`, `film/once`,
  `film/backdrop`) and a layer's motion key by key (`motion/<property>/<thousandths>`, with
  `/given` for a key the app placed itself), so two people keying one layer both keep theirs
  (`Bezzle/Model/FlatDesign.swift`). Keys closer than a frame's quarter are one:
  `BezzleDocument.repairMotion()`.
- **Driving a copy:** `BEZZLE_ANIMATE` and `BEZZLE_FILM` (`Bezzle/App/AnimateHooks.swift`) pick,
  pose, play, press and scrub. Their clock starts when the hook does, well after launch: photograph late.
  `pinch=`, `tap2=`, `wheel=` and `swipe=` send the timeline the events a trackpad or a wheel
  would, through the app's own queue, and `timeline` writes which part of the film shows into
  `BEZZLE_SCRUB_OUT`: the way to see the gestures arrive without a hand on a trackpad.
- **Its words** are in the catalog in all four languages; `AnimateWordsTests` fails when one is
  missing, so a new property, pace or move brings its words along.

### 3D

An artboard is one 3D scene. Everything on it that is turned, brought nearer or pushed away is
seen from one eye in front of the artboard's middle, as far above it as Animate's camera rests
(`Eye.stage`, twice the larger side and never under 600 points). So layers share one vanishing
point, a layer brought nearer grows and comes out from the middle, and what is nearer covers what
is further whatever the layers list says (layers as near as each other keep the list's order). A
group is one card in the scene and orders what it holds inside itself. Off any artboard a layer is
seen from in front of its own middle, as before. The artboard's own sheet is the scene's backdrop:
what is pushed behind the page still shows on it, as CSS paints a parent's background first.
Animate's camera at rest sees what the design shows; tilted or swung, it sees how high each layer
stands, and the sheet still lies under everything.

- **Where:** all shared with Windows and the browser. `Bezzle/Model/Perspective.swift` has `Eye`,
  the homography seen from it, and `BezzleDocument.eye(inside:)` and `eye(forParentOf:)`, where any
  layer is seen from. `DepthOrder.swift` is nearer over further, `DepthPushing.swift` the push
  while dragging, `DepthTurning.swift` the knob and turning from a side. The renderer finds the eye
  itself, from `Options.board` and `offset` (`Renderer.Options.eye`).
- **The rule for new code:** whatever asks where a layer in depth shows (`Perspective`,
  `Geometry.bounds`, `Geometry.contains`, `Renderer.reach`, `Prototype.chain`) is given the eye of
  the layer's parent. Without one it sees the layer from its own middle, which is only right off
  artboards.
- **On the canvas:** Control held while moving layers pushes them away or pulls them nearer, up
  nearer by a point for a point, catching at the page and at the heights of the layers around,
  Shift in tens; pressed or let go during the drag, nothing jumps. The knob takes Control as it
  takes Option. A layer only held at a height and facing the eye has no knob, so a drag on its
  middle moves it. In Animate, Control while moving keys Lift. On Windows the key is Alt, pressed
  once the drag is under way (Alt at the press duplicates).
- **Its tests** are `DepthSceneTests` and `DepthTests`, with `MotionLensTests` for the film.
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
