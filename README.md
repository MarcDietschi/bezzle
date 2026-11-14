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
  A piece whose insides move (a moving shader, a masked or faded group holding a layer that moves)
  is drawn again at every moment, so it is drawn only as it shows then: the part seen through the
  film's frame, as sharp as it is seen (`FilmStageView.seenPart`). The stage draws its pictures in
  the screen's own colour space: in sRGB, Core Animation matched every colour of each new picture
  again on the main thread, which was most of a scrub's time on a screen that is not sRGB.
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
  use), so it keeps what it caught where the sheet creeps along under it. Escape gives back what
  was picked before (`FilmHand.cancel`). The hand asks the keyboard whether Escape is down
  (`heed`: at every step of the drag and sixty times a second while a marquee is in hand),
  because the app is told of no key while SwiftUI follows a press, neither its event monitors
  nor whatever has the keyboard, and Escape does not end SwiftUI's drag either (measured
  2026-11-14 on macOS 27.2 in a test copy). Its tests are `FilmMarqueeTests`.
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
  what was keyed (`BezierPath.Following`, `Node.shapeKeys(following:)`). Both come from
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
  from another shape is first numbered like the one it comes from (`laid(along:)`). Its tests are
  `MotionMatchingTests`. A film asks for it between two keys that say other points
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
  on the artboard and about the layer's own middle, and numbered to come from the key before by
  `Node.shapeValue(taking:at:)`, which gives it points more on its own outline where the outline
  before has points it has none for; `Node.shapesToTake` lists whose a layer can take. Its tests
  are `MotionOutlineKeyTests`, and `AnimateStressTests` keys other outlines and takes them from
  other shapes.
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
  `press=` goes through that queue too and reaches the canvas, the panels and SwiftUI's buttons,
  taps and drags alike, the timeline's among them, in a copy that stays in the background. Of a
  click on a window that is not the one in front, AppKit first asks the view under it whether
  it takes such a click, and SwiftUI says yes for a button and no where it waits for a tap or
  a drag, so the hook has that view's kind say yes while the press lasts (`takesFirstClick`).
  `+` before the points keeps the button down until `lift=`, `escape=1` stands in for Escape
  held down, and `picked` writes what is picked into `BEZZLE_SCRUB_OUT`.
- **Its words** are in the catalog in all four languages; `AnimateWordsTests` fails when one is
  missing, so a new property, pace or move brings its words along.

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
and move, lift and turn where they change); between keys each property goes its own way, so a
group is what keeps layers one thing throughout. The AI server's `turn_layers` does both.

What is nearer covers what is further by the height of each layer's middle, with one exception
that a body needs: layers turned to face the same way, with their middles at different heights,
that lie in one plane or over one another are ordered as parallel faces cover one another, by how
far each plane lies in front, and those in one plane as listed (`DepthOrder.nearness`; the film's
`filmOrder` uses the same). So a button stays on its card when both are swung, though its middle
then stands lower than the card's.

An artboard can be looked at from the side while designing, to see how high each layer stands.
The page is not turned: the eye is moved aside (`DepthLook`, at most 60°), as someone moves their
head in front of a window. So the page and all that lies flat in it stay where they are and every
tool stays true, while what stands off the page shows where the moved eye sees it, with a post
under each corner down to where it would lie (under what is picked alone, when some of it is). On
the Mac, Control dragged beside the layers turns the look (Shift in fives); a click there with
Control, Escape with nothing picked, or the word by the artboard's top right corner looks from the
front again (on Windows the key is Alt, `Windows/README.md` › The app). It is a way of looking, never part of the design: `DocumentStore.looks` holds it and
hands it to the design it shows (`BezzleDocument.looks`, which no file has and `==` leaves out), so
everything on the canvas asks `doc.eye(…)` as ever and is given the moved eye. It is not an undo
step, and it ends when the design is seen as a prototype, inspected or animated. The renderer
sees from the side only where the canvas says so (`Renderer.Options.looks`): exports, films,
thumbnails and the AI server's pictures are always from the front.

A group can be told to keep its layers' depth (`Node.keepsDepth`, the 3D card's switch for a
group, the AI server's `keepsDepth`): CSS's `transform-style: preserve-3d`. What it holds then
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
and `contains`, and `Renderer.reach` all go through; a click on such a layer takes its group, and
inside the group the layer. In a film, such a group with no keys of its own comes apart into
pieces that stand where it puts them (`FilmPiece.stand`), so the camera at rest shows what the
design does and sees between the layers when it moves; with keys of its own it is one card. The
flag is one optional key on a group, written only when set, and one more property shared on its
own (`LayerField`): a Bezzle that does not know it reads the same group as one card.

- **Where:** all shared with Windows and the browser. `Bezzle/Model/Perspective.swift` has `Eye`,
  the homography seen from it, and `BezzleDocument.eye(inside:)` and `eye(forParentOf:)`, where any
  layer is seen from. `DepthOrder.swift` is nearer over further, `DepthPushing.swift` the push
  while dragging, `DepthTurning.swift` the knob and turning from a side, `DepthBody.swift` several
  layers turned as one (`turnInDepth`, `layFlat`, `poseInDepth`), which the Mac's card and pad
  reach through `Store/DepthOperations.swift`, `DepthLooking.swift` the look from the side and
  its posts, which the Mac's canvas turns with `Canvas/LookTool.swift`. The renderer finds the eye
  itself, from `Options.board` and `offset` (`Renderer.Options.eye`).
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
  once the drag is under way (Alt at the press duplicates).
- **Its tests** are `DepthSceneTests`, `DepthTests`, `DepthBodyTests`, `DepthLookTests` and
  `DepthKeepTests`, with `MotionLensTests` for the film.
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
