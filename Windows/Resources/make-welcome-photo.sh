#!/bin/zsh
# Paints the welcome tour's photo as the Mac paints it (Bezzle/Store/WelcomePhoto.swift) into
# Resources/Generated/welcome-lake.jpg, for the Windows build to put beside Bezzle.exe, when the
# painting has changed since it was last made. VM/sync.sh runs it.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
out=$here/Generated
stamp=$out/welcome-lake.jpg
if [[ -f $stamp && $stamp -nt $repo/Bezzle/Store/WelcomePhoto.swift && $stamp -nt $here/welcome-photo.swift ]]; then exit 0; fi
# Its statements run at the top, so it is compiled as main.swift.
work=$(mktemp -d)
cp $here/welcome-photo.swift $work/main.swift
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  xcrun swiftc -O $repo/Bezzle/Store/WelcomePhoto.swift $work/main.swift -o $work/welcome-photo
$work/welcome-photo $out
rm -rf $work
