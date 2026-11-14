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
- **Not built** *(from notes, 2026-11-13)*: zooming the timeline with a pinch, a control for a
  spring's bounce, depth of field, animating looks (colour, corner, border), a lesson in the
  welcome tour.
- **Unchecked:** saving a movie from the sandboxed Release build (1.7 is the first release with
  Animate).
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
- No lesson in the welcome tour.

## Remove Background on Windows *(from notes, 2026-11-08)*

- DirectML not measured on real hardware: speed, memory, integrated graphics at 2,048 pixels.
- Not tried on x64 processors.
- On the processor a picture takes about 10 GB, too much for PCs with 8 to 16 GB.
- Photos in Display P3 are cut in sRGB.

## 3D scenes *(from notes, 2026-11-13)*

- Not built: groups that keep their layers' depth when turned (as CSS `preserve-3d`), turning
  several layers as one body about their common middle, orbiting the Design view.

## The browser viewer

- `Web/README.md` › Not done in the prototype lists what it does not draw or do.
- A few SF Pro and Avenir words come out up to 0.2 pt a letter narrower (`Web/README.md`).

## Housekeeping

- **Agent branches:** eight branches of finished agents are left (`git branch --list 'worktree-agent-*'`,
  those with no worktree in `git worktree list`). Their worktrees are gone and their commits are on
  main, brought there one by one, which is why `git branch -d` refuses them (checked 2026-11-14:
  `git cherry main <branch>` shows every commit as on main, but for bfe9cca and 6b53351, which main
  has in a fuller form as 7737209 and a9aa55c). `git branch -D` removes them.
