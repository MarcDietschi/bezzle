#!/bin/zsh
# Paints the welcome tour's pictures as the Mac paints them, its photo (Bezzle/Store/
# WelcomePhoto.swift) into Resources/Generated/welcome-lake.jpg and its logo to trace
# (Bezzle/Store/WelcomeLogo.swift) into Resources/Generated/welcome-logo.png, for the Windows
# build to put beside Bezzle.exe, when a painting has changed since they were last made.
# VM/sync.sh runs it.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
out=$here/Generated
fresh=1
for made in $out/welcome-lake.jpg $out/welcome-logo.png; do
  for source in $repo/Bezzle/Store/WelcomePhoto.swift $repo/Bezzle/Store/WelcomeLogo.swift $here/welcome-photo.swift; do
    [[ -f $made && $made -nt $source ]] || fresh=0
  done
done
if (( fresh )); then exit 0; fi
# Its statements run at the top, so it is compiled as main.swift.
work=$(mktemp -d)
cp $here/welcome-photo.swift $work/main.swift
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  xcrun swiftc -O $repo/Bezzle/Store/WelcomePhoto.swift $repo/Bezzle/Store/WelcomeLogo.swift $work/main.swift -o $work/welcome-photo
$work/welcome-photo $out
rm -rf $work
