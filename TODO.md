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

- **Shapes with other points:** a Shape key only moves the points the design has, so one outline
  becomes another only with the same points in the same order. A morph between outlines with
  other numbers of points (a star into a circle) would need the two matched or resampled
  (`Bezzle/Model/PathMotion.swift`).
- **Shape keys after a design change of corners:** they follow their points when points are
  added, taken away or dragged (`MotionTrack.realigned`, from `BezzleDocument.setPoints`), but a
  rectangle given round corners in the design, or one whose corners change, gets an outline with
  other points, and its Shape keys then change nothing.
- **Shape keys in points:** a layer resized in the design keeps its Shape changes the same size,
  as Move's are; they do not grow with it.
- **Not built** *(from notes, 2026-11-13)*: depth of field, animating looks (colour, corner,
  border). On the timeline, a marquee over keys (several are picked with Shift).
- **The timeline looked at closer** (2026-11-14): the pinch, two fingers moving it along, the
  double tap and the creep under a drag were driven by tests and by made events in a test copy,
  never felt on a trackpad (the creep's pace, the four times of the double tap, the catch at the
  whole film). A pinch over the canvas while the timeline listens was checked in `FilmZoomTests`
  only. The Bounce number and the Spring chip were photographed in German at one window size.
- **Driving a copy:** `press=` of `BEZZLE_FILM` does not reach SwiftUI's gestures in the
  timeline's header; `AnimateBounceTests.theChipItselfTellsADragFromAClick` shows a way that does.
- **Unchecked:** a movie saved from the sandboxed build onto another disk, where it is copied into
  place instead of renamed. (Checked 2026-11-14 with a sandboxed copy of the Debug build and
  `BEZZLE_FILM` › `movie=`: a new movie through the save panel, one replacing another, and a place
  the sandbox refuses, which is said and leaves nothing behind. The save panel brings the copy to
  the front, so `movie=ask` is for when Erik is not at the Mac.)
- **The browser viewer** keeps a film's keys and shows the design without its film.

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
- **A spring's bounce** has no control, and choosing Spring for keys that are springs puts their
  bounce back to 0.3 (`Host/Animating.swift`); the Mac keeps it (`setPace`). The AI server's
  `get_animation` lists the bounce of a shader input's keys on the Mac; unchecked on Windows.
- **A double click in Prototype and Inspect** may also reach WinUI's double tap and start editing
  the design underneath, as it did in Animate before 114d057 fixed it there.

## Shaders

- **What WebGL does that the engine does not:** framebuffers and render to texture (feedback,
  blur chains), depth and stencil, instancing, video textures and the rest listed in
  `Packages/Shaders/README.md` › What WebGL does that this does not (yet). Such canvases are
  imported as pictures, and the import report says so.
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

## 3D scenes *(from notes, 2026-11-13)*

- Not built: groups that keep their layers' depth when turned (as CSS `preserve-3d`), turning
  several layers as one body about their common middle, orbiting the Design view.

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

- `Web/README.md` › Not done in the prototype lists what it does not draw or do.
- A few SF Pro and Avenir words come out up to 0.2 pt a letter narrower (`Web/README.md`).

## Housekeeping

- **A word nobody reads:** "Twenty-six lessons, about a minute each." is still in
  `Localizable.xcstrings`; neither platform's tour uses it since it has 28 lessons.

- **Agent branches:** eight branches of finished agents are left (`git branch --list 'worktree-agent-*'`,
  those with no worktree in `git worktree list`). Their worktrees are gone and their commits are on
  main, brought there one by one, which is why `git branch -d` refuses them (checked 2026-11-14:
  `git cherry main <branch>` shows every commit as on main, but for bfe9cca and 6b53351, which main
  has in a fuller form as 7737209 and a9aa55c). `git branch -D` removes them.
