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
- **Not built** *(from notes, 2026-11-13)*: depth of field, animating looks (colour, corner,
  border).
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

## Vectorize *(from notes, 2026-11-10)*

- Thin lines in wavering pictures come out whole, but their thickness still wavers.
- Textured pictures make more shapes than vectorizer.ai's.
- Gradients become bands of flat colour (`Blend` is unused).
- 10 point text loses pieces.

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
  its film, and a key's tilt or swing on a layer inside is added to the angles the group gives
  it. Seen exactly edge on, hits and bounds take layers standing off it as lying in it. A
  background blur lying directly in a group makes it one card, which CSS does not do. The switch
  shows only in the 3D card, so a group lying flat needs the card opened first.
- **Groups that keep depth, unchecked:** the switch, the outline and the handles in a window; the
  tiles' redraw around such groups on a live canvas (it rests on `Renderer.reach` and its test);
  a 1.7 copy in a live room beside the new `keepsDepth` entry. Bezzle 1.7 opening and saving such
  a design writes it back without the flag.
- **Web import:** a page's 3D transforms arrive flattened to 2D (`flat(matrix)` in
  `Import/WebPageReader.js`), so nothing imported is in depth and `transform-style: preserve-3d`
  has nothing to keep.
- **Windows, not built:** its AI server lacks `turn_layers` and `keepsDepth`
  (`Windows/Sources/BezzleCore/MCP`); its 3D card, aim pad and fields set each layer alone and
  should call `turnInDepth` and `layFlat`, its Pose card `poseInDepth`; the 3D card lacks the
  switch for groups; looking from the side needs the host's `looks` (handed to `doc.looks`, put
  back after undo, cleared on leaving Design), a gesture, the posts and the word drawn, and a
  redraw of what stands off the page. The shared model is there for all of it.
- **Windows, unchecked in the VM:** turning from a side and the new order of faces turned alike
  (shared `DepthTurning`, `DepthOrder`); a group that keeps depth drawn, picked, its tiles redrawn
  and played in a film (drawing and picking are shared, the tiles' damage is its own).

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

- **Its film is not published:** bezzle.ch/app shows the design without its film until
  `Web/publish.sh` is run and bezzle-web pushed, at Erik's word (the film plays in the viewer since
  2026-11-14, `Web/README.md` › Films).
- **Shader fills** are drawn live only in a film; the design itself shows the fill's picture. A
  moving shader's frame is read back from the graphics card each moment (about 3 ms at 840×600).
  Cube maps, matrix attributes, `#version 300 es` programs and antialias off are written in
  `site/shaders.mjs`, but no test design has them.
- **A film without WebGL** plays at 3 to 9 frames a second on the processor.
- **A film's sharpness while playing:** a piece's whole picture is capped at 4,096 pixels a side
  and 16 megapixels; past that it is sharp only when the film rests.
- **A text set anew at every moment of a film** (wrapped, scaled by a key inside a piece drawn
  again): all text is let go every 600 settings and the film opened again, a wait as at its
  start. Letting go of those texts alone needs `WebText`'s `kept`, shared with Windows, to say
  which; whether Windows grows the same way is unchecked. Each text the page sets costs about
  0.3 MB of CanvasKit's memory.
- **Pictures of the design are never let go:** every artboard drawn stays in the page (`made`,
  `images`), so a shared design drawn again at each edit grows. Older than the film.
- **The film, unchecked:** with the open fonts the published page uses (compared with Apple's
  only), in Safari and Firefox, on a phone, a WebGL context lost mid-film, and the Windows build
  after these commits.
- `Web/README.md` › Not done in the prototype lists what it does not draw or do.
- A few SF Pro and Avenir words come out up to 0.2 pt a letter narrower (`Web/README.md`).

## Housekeeping

- **The VM's disk is nearly full** (11.8 GB free of 127 on 2026-11-14, and a working copy with
  its build takes 5): the source folders of agents finished on 2026-11-13 are still in `C:\src`
  (`win-shaders`, `win-browser`, `win-shapes`, `win-animate`, `win-vectorize` and their small
  side folders, about 22 GB; their work is on main).

- **A word nobody reads:** "Twenty-six lessons, about a minute each." is still in
  `Localizable.xcstrings`; neither platform's tour uses it since it has 28 lessons.

- **Agent branches:** eight branches of finished agents are left (`git branch --list 'worktree-agent-*'`,
  those with no worktree in `git worktree list`). Their worktrees are gone and their commits are on
  main, brought there one by one, which is why `git branch -d` refuses them (checked 2026-11-14:
  `git cherry main <branch>` shows every commit as on main, but for bfe9cca and 6b53351, which main
  has in a fuller form as 7737209 and a9aa55c). `git branch -D` removes them.
