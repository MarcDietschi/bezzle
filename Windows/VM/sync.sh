#!/bin/zsh
# Copies the working tree's Windows build inputs into the Bezzle test VM, at C:\src\Bezzle:
# Windows/, and what it shares with the Mac app and the web core. Symlinks arrive as the files
# they point at. Leaves Windows\Packages and .build there alone.
set -euo pipefail
here=${0:A:h}
cd ${here:h:h}
# The Mac's pointers, as cursors for the Windows build to put into Bezzle.exe.
$here/../Resources/make-cursors.sh
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -ch --exclude .build --exclude Packages --exclude node_modules --exclude 'Web/out' \
    -f - Windows Bezzle/Model Bezzle/Canvas Web/Sources Web/prepare.sh Web/site/openfonts \
  | $here/win 'New-Item -ItemType Directory -Force C:\src\Bezzle | Out-Null; tar -x -f - -C C:\src\Bezzle'
