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
| `Packages/Vectorizer/` | Vectorize's engine: a picture traced into shapes, in plain Swift (the Mac app builds it in; Windows does not have Vectorize yet). Its own tests and a command line that measures it. `README.md` |
| `Scripts/release.sh` | The Mac release. `Scripts/release-windows.sh`: the Windows release. `Scripts/release/`: the notes parser and the Windows feed writer |
| `Scripts/subject-matte/` | Makes Remove Background's model (git-ignored, too large for git) for the Mac and for Windows. `README.md` |
| `RELEASE_NOTES.md` | Every version's notes in English, German, French and Italian; the releases read them |
| `AppStore/screenshots-src/` | Sources of the website's screenshots (the App Store version itself is gone) |
| `~/Sites/bezzle-web` | The website, bezzle.ch: its own repository, mfrports/bezzle-web, with its own `README.md` and `CLAUDE.md` |

## The processes, and where each is written down

| To | Read |
| --- | --- |
| Release a version (Mac, then Windows) | `CLAUDE.md` › Releases |
| Build, run and test the Mac app | below |
| Prove a change to shared code leaves the Mac as it was | below, Mac parity |
| Build, test and ship Bezzle for Windows; work in the VM | `Windows/README.md` |
| Change the website, the download page, the admin area | `~/Sites/bezzle-web/README.md` |
| Deploy or test the sharing relay | `Relay/README.md` |
| Publish the browser viewer | `Web/README.md` › Hosting |
| Make Remove Background's model | `Scripts/subject-matte/README.md` |
| Work on Vectorize's engine, and measure it | `Packages/Vectorizer/README.md` |
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
