# Bezzle for Windows

Bezzle on Windows, native: Swift with WinUI 3 (Erik, 2026-11-06), doing everything the Mac app
does. Nothing here is part of the Mac app's build.

## How it is put together

- **The design's model and its drawing** are the Mac app's own Swift, as the web core shares them
  (`Web/`): `Bezzle/Model`, the renderer, and the stand-ins for what they take from Core Graphics,
  Core Text and the rest (`Web/Sources/BezzleCore/Platform`). Where the web core asks the page
  (CanvasKit) to draw, set text and run path operations, the Windows app asks Skia directly, so
  designs draw and measure on Windows as they do in the browser, which matches the Mac.
- **The window, canvas and panels** are WinUI 3, through Swift bindings that swift-winrt
  generates from the Windows App SDK's metadata.

## Building

Windows builds on Windows: Swift cannot target Windows from macOS, and CrossOver cannot run WinUI 3
(its Windows App SDK needs system calls Wine lacks). On this Mac that is the Bezzle test VM:

```sh
Windows/VM/make-vm.sh        # once: Windows 11 for Arm in UTM, installed unattended (~30 min)
scp …/Windows/VM/provision.ps1, then run it in the VM: Visual Studio Build Tools, Swift, Git, CMake…
Windows/VM/sync.sh           # the working tree's build inputs to C:\src\Bezzle in the VM
Windows/VM/win               # a PowerShell in the VM, or `win <command>`
```

In the VM, in `C:\src\Bezzle\Windows`:

```powershell
.\winrt.ps1                  # WinUI bindings into Packages\, and the Windows App Runtime
swift build
```

See `VM/make-vm.sh` for what the VM is and where its key, password and disks live.

## The app

It looks like the Mac app: `DESIGN.md` has the Mac's numbers, and `Sources/Bezzle/` builds the same
window from them (Theme, Glyphs, Bar, ToolRail, LayersPanel, Inspector, Rulers, DesignCanvas,
HomeView). Designs live in Documents › Bezzle and are saved 600 ms after each change, as on the Mac;
designs shared through their folder (`sharing/people` in the package) are not saved yet.

To try it in the VM without anyone at it: `VM/desktop` runs a command in its signed-in session,
and `VM/input.ps1` there moves the mouse and presses keys (real input, as WinUI needs). With
`BEZZLE_TRACE` set, the app writes what `Trace.say` reports to `%TEMP%\bezzle-trace.log`.
`bezzle-render` draws a design's artboards to PNG files (`BEZZLE_TWICE`, `BEZZLE_FIRST` and
`BEZZLE_HOST_TRACE` for drawing twice, after other designs, and tracing what is missing).
