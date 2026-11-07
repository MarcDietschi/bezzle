#!/bin/zsh
# Draws the Mac's pointers as Windows cursors, into Resources/Generated (see cursors.swift), when
# Cursors.swift or the drawing has changed since they were last made. VM/sync.sh runs it.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
out=$here/Generated
stamp=$out/Bezzle.rc
if [[ -f $stamp && $stamp -nt $repo/Bezzle/Canvas/Cursors.swift && $stamp -nt $here/cursors.swift ]]; then exit 0; fi
# Its statements run at the top, so it is compiled as main.swift.
work=$(mktemp -d)
cp $here/cursors.swift $work/main.swift
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  xcrun swiftc -swift-version 5 -O $repo/Bezzle/Canvas/Cursors.swift $work/main.swift -o $work/cursors
$work/cursors $out
rm -rf $work
