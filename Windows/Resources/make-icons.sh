#!/bin/zsh
# Draws the Mac's app and document icons as Windows icon files into Resources/Generated (see
# icons.swift), when they have changed since they were last made. VM/sync.sh and
# Scripts/release-windows.sh run it; Installer/make-installer.ps1 puts them into the installed app.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
out=$here/Generated
icons=$repo/Bezzle/Assets.xcassets/AppIcon.appiconset
document=$repo/Bezzle/App/BezzleDocument.icns
stamp=$out/BezzleDocument.ico
if [[ -f $stamp && $stamp -nt $here/icons.swift && $stamp -nt $document && $stamp -nt $icons/icon_512x512@2x.png ]]; then exit 0; fi
work=$(mktemp -d)
cp $here/icons.swift $work/main.swift
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  xcrun swiftc -swift-version 5 -O $work/main.swift -o $work/icons
$work/icons $icons $document $out
rm -rf $work
