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

Remove Background runs the Mac's subject matte, BiRefNet_HR, exported to ONNX, with ONNX Runtime
(on the graphics card through DirectML where it can, else on the processor):

```powershell
.\onnx.ps1                   # ONNX Runtime 1.24.4 with DirectML, and DirectML 1.15.4, into Packages\onnxruntime
```

The model itself is made on a Mac and is too large for git (471 MB): `Scripts/subject-matte/make.sh`,
then `make-onnx.sh`, write it to `Scripts/subject-matte/build/onnx/BiRefNet.onnx`, and
`Windows/VM/send-matte.sh [C:\src\<folder>]` sends it into the VM's `Packages\subject-matte`. `onnx.ps1`
says whether it is the model measured (its SHA-256 is pinned there), `build.ps1` links it into
`.build\Bezzle\Bezzle.resources` and puts ONNX Runtime and DirectML beside Bezzle.exe, and the installer
takes only the model measured. Without the headers, Bezzle builds without Remove Background; without
the model, it leaves Remove Background out of the inspector, its menu and the welcome tour.

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

## Working in the VM

The VM is `bezzle@192.168.77.10`, reached by SSH with the key `~/.ssh/bezzle-windows-vm`; its
account's password is in `~/.ssh/bezzle-windows-vm.password` (never print either). `VM/autounattend.xml`
is a template with a placeholder, not the password.

- **Starting it:** UTM has to be running and showing, never hidden: hidden (⌘H, `open -j`, System
  Events' `visible`), it takes the order to start, fails without a word on the VM's window, and the
  VM stays stopped while the order times out (2026-11-10). UTM comes to the front as it is
  launched, even with `open -g`, so note the app in front and give the front back at once:
  `front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true')`,
  then, if `pgrep -x UTM` finds none, `open -g -a UTM; sleep 6; osascript -e "tell application \"$front\" to activate"`,
  then `osascript -e 'tell application "UTM" to start virtual machine "Bezzle Windows"'`. SSH answers
  within half a minute. `utmctl start` prints error -10004 whether the VM starts or not, so ask
  `utmctl list` for its state. If a start timed out, quit UTM and begin again.
- **Commands:** `VM/win '<PowerShell>'` runs over SSH (session 0: no windows, no package installs);
  `VM/desktop [--detach] '<PowerShell>'` runs in the signed-in desktop, where windows appear. A
  program's output over SSH arrives only when it exits. Send a file with non-ASCII text as base64 and
  write it with `[IO.File]::WriteAllBytes` (the console's code page mangles it otherwise), then compare
  `Get-FileHash` with `md5` here. `scp` with `VM/win`'s options fetches results.
- **Sources:** `VM/sync.sh` puts the working tree's build inputs into `C:\src\Bezzle`. Packages are
  built once there (`winrt.ps1`, `skia.ps1`, `avif.ps1`, `onnx.ps1`) and kept. A second working copy
  (a parallel agent's, the release's `C:\src\bezzle-release`) is a folder of its own with a junction
  to `C:\src\Bezzle\Windows\Packages`.
- **Building:** `.\build.ps1` lays out `.build\Bezzle`, which the launchers in `C:\bezzle\*.cmd` run;
  a bare `swift build` does not update it. With several builds at once the VM (8 cores, 12 GB) runs
  out of breath: build with `-j 2` (`swift build -j 2`, `build.ps1 -Jobs 2`).
- **The desktop is one, so it is taken in turn:**
  `until mkdir /private/tmp/claude-501/bezzle-vm-desktop.lock 2>/dev/null; do sleep 30; done; echo <who> > /private/tmp/claude-501/bezzle-vm-desktop.lock/owner`,
  one round of launching, trying and quitting (under about 20 minutes), then
  `rm -rf /private/tmp/claude-501/bezzle-vm-desktop.lock`. Others test without the desktop meanwhile:
  `bezzle-render`, or the AI server over HTTP with the app started minimized.
- **Trying the app:** `VM/input.ps1` (in the VM at `C:\bezzle\input.ps1`) moves the mouse and presses
  keys as real input, which WinUI needs. Every `VM/desktop` call briefly brings its own PowerShell to
  the front, so Bezzle loses focus for a moment and the first input of a call only activates its
  window: begin a call with a harmless click inside Bezzle (the empty part of the inspector), and send
  keys in the same call as that click. Paths go into file dialogs through `Set-Clipboard` and Ctrl+V.
  `VM/desktop --detach '<script>'` with `VM/win 'Start-Sleep <s>'` as a timer catches a gesture midway.
- **Seeing it:** `VM/screenshot [out.png]` photographs the VM's screen from inside it, so it works while
  this Mac's screen is locked; `VM/cursor.ps1` draws the pointer, which screenshots leave out. Copies
  running for an agent use `BEZZLE_NO_MCP=1`, so the AI server's port stays the main session's.
- **Debugging:** `BEZZLE_TRACE` writes `Trace.say` to `%TEMP%\bezzle-trace.log`. Copies started through
  `VM/desktop` run elevated, so `Get-Process` over SSH cannot see their path: look through `VM/desktop`.
  For a crash, set `HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\Bezzle.exe`,
  reproduce it, read the dump with `lldb -b -o "bt 40" --core <dmp> <exe>` in the VM, and remove the
  key. A folder holding macOS `._.` files is removed with `cmd /c del \\?\C:\<folder>\._.` first.
- **A first install, as someone new would:** make a local standard user, sign it in automatically
  (its password as the LSA secret `DefaultPassword`, `DefaultUserName` in Winlogon), restart, run the
  installer in its session through a scheduled task whose principal is that user, launched with
  `conhost.exe --headless powershell …` (a new user's consoles otherwise open in Windows Terminal,
  which covers the screen), and photograph the screen from inside. Afterwards restore the automatic
  sign-in with the real password from `~/.ssh/bezzle-windows-vm.password` and remove the user and its
  profile. Done this way before 1.5 (2026-11-08): the installer registered Windows App Runtime 1.7
  for a new user without administrator rights.
- **What the VM cannot show:** a graphics card (it has no Direct3D 12, so DirectML and its speed are
  untested), a real x64 PC, Smart App Control, and Windows in German, French or Italian.

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

Remove Background is the Mac's (`Host/CutoutMaker.swift`, `CutoutHand.swift`, `Cutouts.swift`,
`SubjectMatte.swift`, copies of the Mac's CutoutMaker, CutoutTool, CutoutOperations and SubjectMatte):
the same model, the same edges and colours, the same outlines, and cutouts named as the Mac names
them, so a design shared between the two finds the other's. What differs is how the subject is
found: the Mac asks Apple's Vision, which Windows lacks; here the matte's own regions are the parts a
click keeps or drops, so subjects that touch are one part. `bezzle-render <fonts> cutout <out>` cuts
the photos `BEZZLE_PHOTOS` names out as Bezzle does (`BEZZLE_MATTE_MODEL`, `BEZZLE_MATTE_DEVICE=cpu`
or `gpu`, `BEZZLE_PICKS`, `BEZZLE_MATTE_RAW` for the matte's floats).

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
  and compiles `Installer/Bezzle.iss`, Remove Background with it: the subject matte measured (it
  refuses any other) and ONNX Runtime and DirectML for its architecture, which take the installer
  from about 99 MiB to about 490 MiB. It installs for the person alone, with no administrator, into
  `%LOCALAPPDATA%\Programs\Bezzle`: a Start menu entry, an entry in Settings › Apps to remove it, the
  `bezzle:` links, Open in Bezzle on a `.bezzle` folder in Explorer, and the Windows App Runtime 1.7
  when it is missing (Microsoft's own installer, run quietly, per user). `-Name 'Bezzle Test'` makes a
  copy that installs beside Bezzle's own (`%LOCALAPPDATA%\Programs\Bezzle Test`).
- **Updates** come through WinSparkle, as the Mac's through Sparkle, from
  https://bezzle.ch/updates/windows/appcast.xml, signed with the Mac's EdDSA key. Only an installed copy
  has them: `-Feed` and `-PublicKey` put WinSparkle.dll beside Bezzle.exe and the feed and key into its
  resources (`Sources/Bezzle/Updates.swift` loads it when it is there). An update runs the new installer
  with `/SILENT /UPDATE=1` from the feed, and Bezzle opens again. WinSparkle has no deltas: each
  update downloads the whole installer, subject matte and all.
- **About Bezzle** (the Bezzle menu) lists what Bezzle is made with; the licences are in
  `Credits/licenses`, which `build.ps1` and the installer put beside Bezzle.exe.
- **A release** is `Scripts/release-windows.sh` on the Mac (a dry run unless given `--publish`): it
  builds the pushed commit in the VM (`C:\src\bezzle-release`), makes the installers for x64 and Arm64,
  signs them and writes the feed; with `--publish` it attaches them to the GitHub release
  `windows-v<version>` of mfrports/bezzle-web, commits the feed there, waits for bezzle.ch to serve
  both and tags the commit. Building takes 30 to 50 minutes an architecture, so a dry run keeps its
  installers (`~/Library/Caches/bezzle-release/windows-made`, the last commit's only), and `--publish`
  of the same commit sends those out without building again, once it has checked they are whole and
  were made for that version, feed, key and open fonts (`--rebuild` builds anew). Its header says
  what it needs; `CLAUDE.md` › Releases has the order, the Mac's release first, at the same version
  and with the same notes.
