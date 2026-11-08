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
.\skia.ps1                   # Skia into Packages\skia
.\avif.ps1                   # libavif and libaom into Packages\avif, for AVIF (a few minutes)
swift build
```

Without `Packages\avif`, Bezzle builds all the same but neither reads nor writes AVIF, as a Mac whose
Image I/O cannot write it leaves the format out. Run `.\avif.ps1` before the first `swift build`; when
it comes after one, touch `Package.swift`, since SwiftPM may keep its earlier reading of the manifest.

`.\build.ps1` builds and lays out the app in `.build\Bezzle`. Most PCs have Intel or AMD processors
(x64), and the Arm VM builds for them too: Swift cross-compiles (`swift build --arch x86_64`, with
`BEZZLE_ARCH=x64` telling `Package.swift` to link the x64 libraries), into `.build\x64`:

```powershell
.\skia.ps1 -Arch x64 -Jobs 2  # Skia into Packages\skia\out\x64 (about 40 minutes with two jobs)
.\avif.ps1 -Arch x64          # libavif and libaom into Packages\avif\out\x64
.\build.ps1 -Arch x64         # the app in .build\x64\Bezzle
```

The x64 app carries Swift's and Visual C++'s runtimes beside `Bezzle.exe` (`runtime.ps1`, from the
merge module Swift's installer leaves and from Visual Studio's redistributable files, only the DLLs
something asks for), since the Swift on an Arm machine's path is Arm's; `-Runtime` does the same for
an Arm build. Its Windows App Runtime bootstrapper is the x64 one of the same Windows App SDK
release. Windows 11 on Arm runs the x64 app by emulation, with the x64 Windows App Runtime that the
Arm runtime installer winrt.ps1 runs puts there beside the Arm one (and x86's).

A release build is of the app alone, `.\build.ps1 -Configuration release -Product Bezzle` (either
architecture): bezzle-share imports the core `@testable`, which a release build refuses.

See `VM/make-vm.sh` for what the VM is and where its key, password and disks live.

## The app

It looks like the Mac app: `DESIGN.md` has the Mac's numbers, and `Sources/Bezzle/` builds the same
window from them (Theme, Glyphs, Bar, ToolRail, LayersPanel, Inspector, Rulers, DesignCanvas,
HomeView). Designs live in Documents › Bezzle and are saved 600 ms after each change, as on the Mac;
designs shared through a synced folder (`sharing/people` in the package) are saved as the Mac saves
them (Host/Collaborating.swift).

To try it in the VM without anyone at it: `VM/desktop` runs a command in its signed-in session,
and `VM/input.ps1` there moves the mouse and presses keys (real input, as WinUI needs). With
`BEZZLE_TRACE` set, the app writes what `Trace.say` reports to `%TEMP%\bezzle-trace.log`.
`bezzle-render` draws a design's artboards to PNG files (`BEZZLE_TWICE`, `BEZZLE_FIRST` and
`BEZZLE_HOST_TRACE` for drawing twice, after other designs, and tracing what is missing). Given a
file from Adobe XD, Figma, Sketch or Photoshop instead, it brings it in first, as the app does
(into the out folder, or `BEZZLE_IMPORT_TO`), says what came across, and draws the new design.
Given a web page's address (`https://…` or `file:///…`), it brings the page in as Import from a
Website does (`BEZZLE_WEB_WIDTHS=1440,390`, `BEZZLE_WEB_BANNERS` keeps cookie banners,
`BEZZLE_WEB_SCALE` the pixels to a CSS pixel). WebView2 refuses SSH's session 0, so run it in the
signed-in session (a scheduled task); its window is cloaked and never in front.
`BEZZLE_TEXTS=<file>` writes instead how the core measures the design's texts and probe texts in
every family the open fonts stand in for (lines, baselines, widths, fitted frames;
`Host/TextReport.swift`), to compare with Text Kit on the Mac; `BEZZLE_INK=<file>` where letters
are drawn against their baselines.

Web pages are read in WebView2, the Edge engine Windows 11 has (`CBezzleHost/webview.cpp`, its
SDK fetched by `winrt.ps1` into `Packages\webview2`), by the Mac's own page reader
(`Bezzle/Import/WebPageReader.js` and `WebPageAwake.js`, built into the core) and the Mac's
converter (`WebImporter.swift`, `WebPage.swift`, `CSSValues.swift`, linked); `Import/WebCapture.swift`
is the Mac's WebCapture with WebKit's calls asked of the DevTools protocol instead. As on the Mac,
home's From a Website… button, the Bezzle menu's Import from a Website… (Ctrl+Alt+Shift+I), a
link dropped on home and the AI tool `import_website` bring one in (`WebImportSheet.swift`).
`BEZZLE_LIBRARY` gives a test copy a designs folder of its own.

Files from other apps are brought in by the Mac's own importers (`Bezzle/Import`, linked into
`Sources/BezzleCore/Import` beside the Windows stand-ins for what they take from AppKit, Image I/O
and Core Text); home's Bring In… button, the Bezzle menu, files dropped on home and a file given
on the command line all bring one in.

## Shipping it

Bezzle for Windows is a download from bezzle.ch beside the Mac's, unsigned (Erik, 2026-11-07: no
Store, no paid certificate), so Windows asks once, for the installer someone downloads, whether to
run an app from an unknown publisher (More info, then Run anyway).

- **The installer** (`Installer/`) is made with Inno Setup 6, pinned with its SHA-256 like everything
  `Installer/fetch.ps1` fetches (Inno Setup, WinSparkle, Microsoft's Windows App Runtime installer).
  `Installer/make-installer.ps1 -Version 1.4.2 -Build 20261108.1200 [-Arch x64]` takes the app
  `build.ps1 release` laid out, puts the Swift runtime and the C++ runtime beside Bezzle.exe (whatever
  it needs that Windows has not), strips Bezzle.exe's debugging information (kept beside the
  installer as `Bezzle-<v>-<arch>.pdb.exe` for reading crashes), writes its icon and version into it,
  and compiles `Installer/Bezzle.iss`. It installs for the person alone, with no administrator, into
  `%LOCALAPPDATA%\Programs\Bezzle`: a Start menu entry, an entry in Settings › Apps to remove it, the
  `bezzle:` links, Open in Bezzle on a `.bezzle` folder in Explorer, and the Windows App Runtime 1.7
  when it is missing (Microsoft's own installer, run quietly, per user). `-Name 'Bezzle Test'` makes a
  copy that installs beside Bezzle's own (`%LOCALAPPDATA%\Programs\Bezzle Test`).
- **Updates** come through WinSparkle, as the Mac's through Sparkle, from
  https://bezzle.ch/updates/windows/appcast.xml, signed with the Mac's EdDSA key. Only an installed copy
  has them: `-Feed` and `-PublicKey` put WinSparkle.dll beside Bezzle.exe and the feed and key into its
  resources (`Sources/Bezzle/Updates.swift` loads it when it is there). An update runs the new installer
  with `/SILENT /UPDATE=1` from the feed, and Bezzle opens again.
- **About Bezzle** (the Bezzle menu) lists what Bezzle is made with; the licences are in
  `Credits/licenses`, which `build.ps1` and the installer put beside Bezzle.exe.
- **A release** is `Scripts/release-windows.sh` on the Mac (a dry run unless given `--publish`): it
  builds the commit in the VM, makes the installers for x64 and Arm64, signs them and writes the feed.
