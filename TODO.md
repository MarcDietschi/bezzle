# What is left

Everything known to be missing, unfinished or unchecked, by area. Each item says where it lives
and when it was found. A session that leaves a gap adds it here; one that closes a gap takes the
item out in the same commit. Larger lists of their own stay where they are and are linked from
here, such as `Web/README.md` › Not done in the prototype.

Items marked *(from notes)* were carried over from session notes and not checked again when this
file was made (2026-11-14): look before starting on one.

## In progress

- **Windows: scrubbing and playing in Animate keep pace.** The Mac's speed work (66d6a3c) being
  brought to Windows: the four film placements that still search the artboard per piece
  (`Host/FilmStage.swift`, `Host/FilmMovie.swift`, `Host/MotionHand.swift`), a scrub measure for
  Windows, and the Windows sides of what slowed the Mac. Not in 1.7.

## Animate

### Mac and shared

- **Shape keys that go with the design** (2026-11-14: a layer resized, rounded or flipped in the
  design takes its Shape keys along, `BezzleDocument.followOutlines`). Left: a key another person
  adds for the old size while a resize is merged stays unscaled; a rectangle's corners rounded
  and squared again lose a little of the keyed reshaping (about 47 of 50 points come back); a new
  component copy made at another size takes the component's keys unscaled.
- **Outlines with other points** (2026-11-14: points added and taken away at the playhead, and
  From… in the Pose card's Shape row gives a shape another's outline). A shape given another's
  outline gets extra points where the outline before has points it has none for (a rectangle
  after a triangle has six), and points taken in hand between two such keys are the matched
  outline with those extras. From… ignores a 3D turn of either shape and takes only shapes on
  the film's own artboard. Its menu and the hover preview were never looked at in a running
  window; adding and deleting points is driven through canvas events in tests only.
- **Outline keys in Bezzle 1.7:** it shows the design at such a key and keeps the key whole. Where
  the design's outline gets more points while such a key keeps its old count of noughts (points
  added in 1.7, or one person keying while another edits the design's points), 1.7 shows the
  stretch to that key bent; this Bezzle reads the key right and rewrites it at its next change.
- **Not built** *(from notes, 2026-11-13)*: depth of field.
- **Looks keyed in Animate** (2026-11-14: fill and text colour, gradient colours and their
  places, border colour and width, a rectangle's corners, shadows; `Bezzle/Model/LookMotion.swift`).
  Not keyed: picture and shader fills, on and off, adding and taking away, dashes, a border's
  side, a shadow inside or outside, blend, smooth corners, a gradient's line, ends and count of
  colours. A look change made in Animate that no picked layer can key (a picture swapped, a fill
  turned off) changes the design as before, with no word that it did.
- **Keyed looks, as chosen:** a keyed colour is a colour of its own, so it cannot be a named
  colour or a variable and does not turn with a dark artboard (only the keys the app gave follow
  the design). A rectangle whose Shape has keys keeps the design's corners: its Corners keys wait
  and show faint, the card and the corner dots are not offered, the AI server refuses; rounding
  it over time takes a Shape key with rounder corners. Hover previews of presets and styles do
  not show on the film, and no ready-made move changes a look. A rectangle's corner dots show
  only for one picked rectangle drawn as a piece of its own and at least 48 points each way.
- **Keyed looks, unchecked:** photographed in German at one window size before the marquee, the
  outline keys and the gentle tones were on main; gradient colours, the beads, the corner dots
  and the marquee over a look's line are driven by tests only. Scrub speed was measured on 1.7's
  base only (120 steps a second, longest gap 11.1 ms, 49 layers of which 7 change look), not
  since the movie's sixteen-bit pictures; a movie with keyed looks was made in a test only.
  Restacking or removing fills while another person keys them was tested through the model's
  merge, never with two copies in a live room.
- **Look keys in Bezzle 1.7:** kept, and the design's look shown. A whole-layer retime there
  leaves them at their old moments, Remove Motion takes them, and a layer with only look keys
  has no line.
- **The timeline looked at closer** (2026-11-14): the pinch, two fingers moving it along, the
  double tap and the creep under a drag were driven by tests and by made events in a test copy,
  never felt on a trackpad (the creep's pace, the four times of the double tap, the catch at the
  whole film). A pinch over the canvas while the timeline listens was checked in `FilmZoomTests`
  only. The Bounce number and the Spring chip were photographed in German at one window size.
- **Gentle tones in a movie** (2026-11-14: kept in sixteen bits until the one cut to the movie's
  steps, and HEVC with ten bits beside H.264). Still cut twice, with eight bits: a layer turned
  in depth inside a piece (`Depth.swift`), and a piece holding Plus Lighter, Plus Darker, Color
  Dodge, Color Burn, Hue, Saturation, Color or Luminosity, or a background blur made lighter or
  darker. Core Graphics casts a shadow's mask with eight bits even then. Such pieces take twice
  the memory in a movie. Not built: grain in the design, the only remedy once a video site packs
  a movie again with eight bits (tried with x264 standing in for a site, never with a real one).
- **HEVC with ten bits, unchecked:** read back with AVFoundation, ffmpeg and headless Chrome, but
  not opened in QuickTime Player's window, Safari, iOS, Windows, Firefox or VLC; "This Mac cannot
  save a movie of this kind" was never seen for real.
- **Bands outside movies** (measured 2026-11-14, not changed): shadows and blurs in an exported
  PNG are plain eight bits, a JPEG wipes out the dither Core Graphics gives gradients, and what
  the stage shows on screen was not measured beyond its pieces being eight bits.
- **The marquee over keys** (2026-11-14: a drag from the timeline's bare sheet picks the keys it
  touches; the ruler and the playhead's own line move the playhead). Escape is read from the
  keyboard's state (`FilmHand.escapeOnKeyboard`), because the app hears no key while SwiftUI
  follows a press: driven by tests with a stand-in for the key, never with a real key, never in
  the sandboxed release build. Never felt: drawn once in a background copy by made presses; the 3
  points before it begins, the 4 within which it catches a bead and the 4 that take the
  playhead's line were not tried with a pointer.
- **The marquee, not built:** Escape under other drags on the timeline (a key, a bar, the playhead
  or the film's end dragged is not given back; `FilmHand.heed` could do it). It begins only on
  bare sheet: where every line's bar runs the film's length and the card shows no spare line,
  there is none to begin on. In a film of more than seven lines it does not scroll the lines up
  or down, it creeps only along the film, and Escape leaves the sheet where it crept to. Shift
  is read as the press comes. Keys cannot be copied in Animate, so a marquee's keys move and are
  deleted together but are not copied.
- **Driving a copy:** `press=` replaces `acceptsFirstMouse` on the kind of view under the point
  while the press lasts (Debug only).
- **Unchecked:** a movie saved from the sandboxed build onto another disk, where it is copied into
  place instead of renamed. (Checked 2026-11-14 with a sandboxed copy of the Debug build and
  `BEZZLE_FILM` › `movie=`: a new movie through the save panel, one replacing another, and a place
  the sandbox refuses, which is said and leaves nothing behind. The save panel brings the copy to
  the front, so `movie=ask` is for when Erik is not at the Mac.)

### Windows

- **Not done** (from the port, 2026-11-13): pinch and twist on the camera, the timeline's springs
  and the trackpad's taps of feedback, the small blur of the Focus chip, sharper parts while the
  film plays, time labels on the render sheet.
- **Different from the Mac:** movies go up to 120 frames a second (the Mac's 240); the stage is
  put together on the processor and was only measured in the VM, never on a real PC.
- **Shapes** (2026-11-14): the Draw chip's home box is drawn solid where the Mac's is dashed, and
  chips do not grow a little under the pointer. The AI server's shape and draw keys were built
  but not run on Windows.
- **The timeline shows the whole film only** (2026-11-14): no looking closer, no moving a part
  along, no page turned as the film plays, no strokes finer than tenths. The shared `FilmWindow`
  and `FilmScale.zoomed` and `scrolled` are there for it (`Bezzle/Model/FilmKeys.swift`, not yet
  built for Windows or the browser); `Host/FilmHand.swift` builds its scale from the whole film
  and moves keys by the pointer's distance, not by the moment under it.
- **A movie's gentle tones** are still rounded twice (pieces and the frame in eight bits, then
  NV12), and there is no ten bit choice; the AI server's `codec` is the Mac's alone. What it
  takes is in e652531's report: `bz_film_frame` composing in sixteen bits, the stand-in pictures
  carrying depth, P010 and an HEVC Main 10 encoder where the PC has one, measured with
  `FilmBandingTests` and `TEST_RUNNER_ANIMATE_BANDING_MOVIE`.
- **A spring's bounce** has no control, and choosing Spring for keys that are springs puts their
  bounce back to 0.3 (`Host/Animating.swift`); the Mac keeps it (`setPace`). The AI server's
  `get_animation` lists the bounce of a shader input's keys on the Mac; unchecked on Windows.
- **Shape keys** do not follow a resized, rounded or flipped design (one call:
  `next.followOutlines(since:start:)` in `Host/Editing.swift` after `fitCarousels`), and points
  added or deleted in Animate, From… and the AI server's `outlineOf` are not there
  (`Host/FilmPoints.swift` still passes `pointsFixed`, `AnimatePanel.swift` has no From… chip,
  `MCP/MCPAnimate.swift` refuses a path with other points). A film with outline keys made on the
  Mac plays there, since the drawing is shared; unchecked in the VM.
- **The timeline has no marquee over keys,** and bare sheet dragged still moves the playhead
  there. The shared `FilmMarquee` (`Bezzle/Model/FilmKeys.swift`) is tested and there to use.
- **The film's parts:** `Host/FilmMovie.swift` and `Host/FilmStage.swift` ask
  `insetBy(…).contains(…)` of Foundation's own `CGRect`, whose `contains` is `union(r) == self`
  as the browser's stand-in was, so Windows may draw parts needlessly as the browser did
  (`WebFilm.holds` is the remedy there). Not measured. The Mac was measured (2,495 askings in
  eight films, none answered wrongly) and draws nothing needlessly.
- **Keyed looks** (the Mac's since 2026-11-14) are not built for Windows and were never run in
  the VM. The stage and the movie should draw them through shared code (`piece.changes`,
  `Node.posed`) and the timeline lists their lines from the shared `FilmRow.rows`, but
  `Host/FilmHand.swift` and `Host/Animating.swift` (`tracks(of:)`, `retime`) do not pass `look:`,
  so a key on a look's line stands for every key of the layer at that moment when dragged, paced
  or deleted; twice on a look's line and "Add Key Here" hold the whole layer (`holdHere`) where
  the Mac toggles that look's key; `FilmRow.Mark.gone` is not drawn faint. There are no look
  cards at the playhead in `AnimatePanel.swift`, no beads and no corner dots, so a look cannot
  be keyed by hand (to call: `Node.looked(at:)`, `poseLooks(at:_:)`, `fits`, `lookValue(_:at:)`,
  `setLookKey`). The AI server has no `look` in `animate` and lists none in `get_animation`.
- **A double click in Prototype and Inspect** may also reach WinUI's double tap and start editing
  the design underneath, as it did in Animate before 114d057 fixed it there.

## Shaders

- **Kept live since 2026-11-14 on the Mac:** canvases that draw through framebuffers (blur chains,
  feedback), with depth and stencil tests, culling, masks, scissor, instances, several outputs,
  textures of numbers, uniform blocks and a blend constant. Checked with pages of our own that
  imitate the calls of three.js, PixiJS, regl and ogl, never with the real libraries or a real
  website, and never looked at in a running window.
- **Not recorded on import** (the canvas stays a picture and the report says why): cube maps as
  targets, `gl_FragDepth`, sampled depth textures, 3D, array, multisampled and integer targets,
  `clearBuffer` of one of several outputs, `copyTexImage2D`, a blit from the canvas, transform
  feedback, pages driven by `readPixels`, compressed textures, WebGL 1 `gl_FragColor` to several
  outputs. A page that uploads its buffers anew every frame (PixiJS batches) is kept still.
  Uniforms counted per frame run as slowly as the reading web view drew.
- **Video textures** are the frame at capture only ("Videos in WebGL drawings, as still
  pictures"); playing one needs the video's file kept in the design, decoding per film frame and
  a mapping of film time to video time.
- **What a fill keeps:** kept state over 12 MB, or unreadable, makes the canvas a picture; the
  contents of targets and textures of numbers live as base64 in the design's JSON (keeping them
  as files would be a format change). A 1.7 that saves such a design again drops the `scene` key
  and keeps the picture.
- **In a film:** a fill that builds on its frames is drawn in steps; a far jump forward draws
  every step between once, and steps stop at 36,000.
- **Direct3D draws none of it:** passes into textures, depth and stencil, culling, colour masks,
  scissor, polygon offset, instances, several outputs and textures of numbers are refused by
  name and such fills show their picture on Windows. It needs targets with formats, several
  outputs, depth-stencil and rasterizer states, write masks, instanced draws, mipmaps of targets
  and float read-back in `ShaderDirect3D.h/.cpp` and `Direct3D/Renderer.swift`, mirroring
  Metal's `run`, `targets(of:)` and `Timelines`; then `TargetsTests`, `StateTests` and the 17
  Agreement frames are turned on (`drawsPasses` in `Tests/ShadersTests/Support.swift`). On
  Windows a web import keeps such a canvas as a picture; that path is compiled, never run in
  the app.
- **The browser viewer** shows the picture for such a fill (`beyondPlain`); drawing it needs
  framebuffer passes, steps with kept state, a depth and stencil context, instancing, textures
  of numbers and per-draw clocks in `site/shaders.mjs`.
- **For Erik:** the glow layer of the Lawsearch AI design was recorded before the recorder was
  fixed (2026-11-13); importing it again gives the fixed recording.

## Vectorize

Worked on 2026-11-14 (`Packages/Vectorizer/README.md` has the measures): colours that run become
gradient fills, thin lines come out evenly thick, small text keeps most of its pieces, textured
pictures make fewer shapes. What is still open:

- **Thin lines:** a line a pixel thick in a picture that wavers comes out about a fifth too thick
  (1.15 to 1.25); its two edges are found each on its own.
- **Textured pictures** still make more shapes than vectorizer.ai's where long thin lines along
  edges break up (243 to their 193, 113 to 87), and nothing is taken away in pictures traced at a
  smaller size than their own (129 to 105).
- **Gradients:** colours that run round a point, along a bend or outward in ovals stay bands of
  flat colour; so does a faint run in a noisy picture. The Vector card's colours
  (`Tracing.palette`) list a run's bands, not its gradient. In a JPEG the edge of a shape beside
  a run keeps a notch here and there, and the ground of the gradients sample comes out in two
  halves.
- **10 point text** loses strokes and gaps thinner than a pixel (6 of 140 pieces, 10 of 46
  counters closed, 14 letters run together); a dot on the corner of four pixels reads up to three
  times too large.
- **Large pictures:** one of more than about 1.6 megapixels is read with one sample to a pixel
  and its outlines may lie 0.6 px off (0.2 in a small picture); a circle there is not always
  known for an ellipse.
- **Time:** last measured on a calm Mac for the state of c03f41f's content; the three later
  commits only on a busy one. A photograph's time has not been measured since 2026-11-10.
- **Never looked at in a window** with the new engine, on the Mac or Windows.
- **Windows:** the vectorize tool's description in `Windows/Sources/BezzleCore/MCP/MCPDefinitions.swift`
  still says every layer is flat in colour; gradient layers were not built or looked at in the
  VM (they come through the shared `Bezzle/Model/Vectorizing.swift`, round ones with
  `Gradient.across`).

## Remove Background on Windows

- DirectML is not measured on real hardware (speed, memory, integrated graphics at 2,048 pixels),
  so the card's measures in `MatteWays` are guesses. It takes a real PC and the first version
  after 1.7: `Scripts/subject-matte/README.md` › Measuring a graphics card.
- Not run on a real x64 processor: under emulation in the VM it cuts out correctly (2026-11-14),
  which says nothing of its speed.
- No PC of 4 or 8 GB has run it: in the VM the light size holds 1.7 GB, and 1.2 GB the lean way,
  taken with less than 2.2 GB left (`BEZZLE_MATTE_LEFT` tries the choice, not real pressure).
- The new ways (2026-11-14) ran through `bezzle-render`, not the app: the line the app writes to
  its trace after each matte was not read from an app's own trace file, and their times were not
  taken in a quiet VM.

## 3D scenes

Built 2026-11-14 on the Mac (`README.md` › 3D): several layers turned as one body, an artboard
looked at from the side, groups that keep their layers' depth. None of it was seen in a real
window, only in tests and in pictures the renderer made. What that left:

- **For Erik, looking from the side:** it moves the eye and leaves the page where it is, so every
  tool stays true while looking (`DepthLook`); a true orbit that tilts the page is not built. Say
  if the page itself should turn.
- **Looking from the side:** no menu command. The word "Look from the Front" may sit over a
  carousel's slide numbers, and the posts are drawn over everything. Under a layer standing in a
  group that keeps depth the posts go down to the group's plane, not the page; looking from the
  side at such groups has no test.
- **One body:** Animate's canvas grips still tip or swing one layer; only the Pose card and the AI
  server's `turn_layers` pose several as one body. A body posed by keys is rigid at each key and
  only nearly so between them (its angles ease one by one). A body's lead can change between
  turns when a group's fitted frame outgrows it, and angles are kept to hundredths of a degree,
  so a body facing several ways drifts by thousandths of a point over many turns.
- **Groups that keep depth, different or not built:** SVG export writes a turned or lifted one as
  one picture, true inside itself but not ordered among the layers beside it (PNG, JPEG, PDF,
  tiles, thumbnails and films are true). The prototype player's hit test (`Prototype.chain`)
  orders per group, not across such a group's border. One with keys of its own is one card in
  its film. Seen exactly edge on, hits and bounds take layers standing off it as lying in it. A
  background blur lying directly in a group makes it one card, which CSS does not do. The switch
  shows only in the 3D card, so a group lying flat needs the card opened first.
- **Groups that keep depth, unchecked:** the switch, the outline and the handles in a window; the
  tiles' redraw around such groups on a live canvas (it rests on `Renderer.reach` and its test);
  a 1.7 copy in a live room beside the new `keepsDepth` entry. Bezzle 1.7 opening and saving such
  a design writes it back without the flag.
- **Web import:** a page's 3D transforms arrive flattened to 2D (`flat(matrix)` in
  `Import/WebPageReader.js`), so nothing imported is in depth and `transform-style: preserve-3d`
  has nothing to keep.
- **The design's own order can hide a layer** (found 2026-11-14, not fixed since it changes how
  designs draw): faces turned alike in one plane, with middles exactly as high as each other, are
  not joined as one body by `DepthOrder.nearness`, so when something standing over one of them
  raises it, the other stays behind. A title in the middle of a turned plate is drawn under the
  plate when a badge is held over the plate's higher end (group at 100, 50, 200, 100, swing −40,
  z 30; Plate full size; Title 80, 44, 40, 12; Badge 170, 4, 26, 26 at z 12: the design draws
  Title, Plate, Badge). A fix must not shift, by rounding, the keys of faces as near as each
  other. The film keeps the run together and shows the title, so film and design differ there
  (`DepthFilmTests` pins the film's side only).
- **Animate, dragging inside a turned group** (keeping depth or one card, the Mac's
  `MotionTool.travel` and Windows' `MotionHand.travel` alike): the Move is as long as the pointer
  went across the page, laid along the group's plane, so the layer lags the pointer by the
  group's foreshortening.
- **Films of groups that keep depth** (order at rest and keys measured in the group, fixed
  2026-11-14 in the shared model): Windows was not built or run with the fix; run
  `Windows/VM/depth-agreement.sh` again with a fresh out folder, since the Mac's "Resting" and
  "Turning" frames changed. Untested: a layer pinned by its corners lying in a turned group that
  keeps depth.
- **Windows** has all three since 2026-11-14 (the card and the AI server turn bodies, the group's
  switch, the look from the side with Alt; `Windows/README.md` › The app), measured against the
  Mac's renderer (`Windows/VM/depth-agreement.sh`) and seen in the app's window. Left there:
  Animate's Pose card keys Tilt and Swing of several layers each alone (`Host/Animating.swift`,
  `pose(_:number:to:)` should call `poseInDepth`); Escape does not let go of what is picked in
  Design, so it looks from the front only with nothing picked; a look from the side cannot be
  begun in a read-only design or while looking back at versions; with no tiles, an artboard
  looked at from the side is drawn whole at every step of the drag (not measured on a large
  one); the 3D card's numbers follow a turn from a side only when the drag ends.
- **Windows, not checked:** the switch and captions in German, French and Italian in the window;
  a deck's artboard looked at from the side; the x64 build; a film of a group that keeps depth
  playing in the window (only at rest there).
- **Not looked at on the Mac:** whether the 3D card's row cuts "Layers keep their depth" (Windows
  uses a wrapping row).

## The welcome tour

- **Windows:** the lessons on Vectorize and Animate (2026-11-14) were looked at with
  `bezzle-render` only, never in the app's window.
- **Windows, the tour's film:** turning to Animate keeps an artboard clear of a timeline of four
  lines only and centres it both ways (`DesignCanvas.frameFilm`, `FilmTimelineView.foot`); the Mac
  counts the film's lines and moves it only the way it must (5b0c1f4). The postcard's film has
  seven lines, so its foot can lie under the timeline and its words leave the view.
- **Windows releases 1.5 to 1.7 shipped the tour without its photo** (grey boxes in Photo editing,
  Masks, Adaptive layout and Gradients and pictures; seen in the release's build folder and with
  the render tool, not in an installed copy). `Scripts/release-windows.sh` paints the tour's
  pictures since e9046e7 and the installer refuses an app without them; the next Windows release
  is the first real run of that.
- **Unchecked on the Mac:** Space playing the postcard's film by a pressed key (the hook sends key
  down only; the code path and the `start` hook were run), and Vectorize's pencil pass over the
  badge in a photograph.
- **For Erik:** three handwritten notes of older lessons end in exclamation marks ("Go on, move
  one!", "into the sky!", "your turn!"). Left as they were.

## The browser viewer

Worked through on 2026-11-14 (`Web/README.md` › What the prototype left out, and what is drawn
now, with the numbers): plus darker, blurs along a ramp, shader fills in the design, the live
room's hands and presence, four languages, the icon library in the core, and memory let go.

- **Nothing of this is published:** bezzle.ch/app shows none of the mended drawing, the live
  room, the four languages or the film until `Web/publish.sh` is run and bezzle-web pushed, at
  Erik's word (`publish.sh` also copies `live.mjs` and `words.mjs`).
- **Shader fills** beyond plain draws (passes into textures, steps building on frames before,
  depth, stencil, instances, textures of numbers; `beyondPlain`), and every shader fill where
  there is no WebGL, show their picture, in the design and in a film; drawing them needs
  framebuffer passes, steps with kept state, a depth and stencil context, instancing, textures
  of numbers and per-draw clocks in `site/shaders.mjs`. A moving shader's frame is read back
  from the graphics card each moment (about 3 ms at 840×600). Cube maps, matrix attributes,
  `#version 300 es` programs and antialias off are written there, but no test design has them.
- **The live room** does not show a layer moving while it is dragged (it moves when the drag
  ends), the glow of what was just changed, the light where others look, pictures on their way,
  or following someone's view. Tested with the words two real Mac rooms said (`LiveTruthTests`)
  and stand-ins on a local relay; never tried by hand with a Mac in the room.
- **Words:** `Web/site/index.html`, the sample viewer for this Mac, is in English alone.
- **Text widths:** at sizes that are not whole every face is up to a 64th of the size narrower
  (FreeType takes sizes in 64ths; 0.10 pt on a word of 230 pt), and the system font's heavier
  weights are up to 0.2 pt wider on a word at 96 pt (whole-unit advances at a weight between the
  font's own). Both inside CanvasKit; measured with Apple's fonts, while the published page sets
  open stand-ins.
- **A film without WebGL** plays at 5 to 12 frames a second on the processor.
- **A film's sharpness while playing:** a piece's whole picture is capped at 4,096 pixels a side
  and 16 megapixels; past that it is sharp only when the film rests.
- **A film's gentle tones:** the page draws each piece of a film with eight bits, where the Mac's
  movie keeps pieces finer and cuts once: up to 2 levels of 255.
- **Not set beside the Mac in the viewer:** 3D bodies and the look from the side, groups that
  keep depth, Shape keys with other outlines, and looks keyed in a film (drawn through the
  shared `FilmPictures.subject` and `piece.changes`; the core compiles with them).
- **The icon library** is read by the core (`bz.icons`), but no page uses it and `publish.sh`
  does not copy `Icons.deflate`; placing an icon would be editing, which the viewer leaves out
  at Erik's wish.
- **Unchecked:** the film with the open fonts the published page uses (compared with Apple's
  only), in Safari and Firefox, on a phone, a WebGL context lost mid-film.
- **Windows, not checked after these commits:** the build (`Platform`, `Web` and `Bezzle/Model`
  files changed, additively); whether it keeps texts as the page did before `HostTexts`; and
  its host's `pathOp`, which hands on Skia's Simplify and Op results as they come (even-odd,
  contours either way round) and strokes at Skia's default precision, so Lucide icons whose
  lines enclose something and combined shapes with holes may fill in, as they did in the page
  before `wound` (the cure could move into `Platform/CGPath.swift`).
- `Web/README.md` › Not done lists what the viewer still does not draw or do.

## Housekeeping

- **The VM's disk** had 5.5 GB free of 127 on 2026-11-14, with a working copy and its build
  taking 5. The build folders of agents finished before 1.7 (`win-shaders`, `win-browser`,
  `win-animate`, `win-vectorize`) were removed then, which left 21.9 GB; their small side folders
  of designs and pictures, `cutout-samples`, `import-samples` and about 250 old
  `C:\bezzle\BezzleDesktop-*.log` files are still there.

- **A word nobody reads:** "Twenty-six lessons, about a minute each." is still in
  `Localizable.xcstrings`; neither platform's tour uses it since it has 28 lessons.

- **Agent branches:** eight branches of finished agents are left (`git branch --list 'worktree-agent-*'`,
  those with no worktree in `git worktree list`). Their worktrees are gone and their commits are on
  main, brought there one by one, which is why `git branch -d` refuses them (checked 2026-11-14:
  `git cherry main <branch>` shows every commit as on main, but for bfe9cca and 6b53351, which main
  has in a fuller form as 7737209 and a9aa55c). `git branch -D` removes them.
