#!/bin/zsh
# Copies the working tree's Windows build inputs into the Bezzle test VM, at C:\src\Bezzle or the
# folder given (a second working copy's, `sync.sh 'C:\src\<folder>'`): Windows/, and what it shares
# with the Mac app and the web core, the Vectorize engine (Packages/Vectorizer) among it. Symlinks
# arrive as the files they point at. Leaves Windows\Packages and .build there alone.
set -euo pipefail
here=${0:A:h}
dest=${1:-'C:\src\Bezzle'}
cd ${here:h:h}
# The Mac's pointers, as cursors for the Windows build to put into Bezzle.exe.
$here/../Resources/make-cursors.sh
# The Mac's words in German, French and Italian, for the Windows build to put beside Bezzle.exe.
$here/../Resources/make-strings.py
# The Mac's app and document icons, for the installer to put into Bezzle.exe.
$here/../Resources/make-icons.sh
# The Mac's version (Xcode's MARKETING_VERSION), which a copy built in the VM says it is.
sed -nE 's/^[[:space:]]*MARKETING_VERSION = "?([^";]+)"?;$/\1/p' Bezzle.xcodeproj/project.pbxproj | sort -u | head -1 \
  > $here/../Resources/Generated/version.txt
# The welcome tour's lake photo, painted as the Mac paints it, for the build to put into Bezzle.resources.
$here/../Resources/make-welcome-photo.sh
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -ch --exclude .build --exclude Windows/Packages --exclude node_modules --exclude 'Web/out' \
    -f - Windows Bezzle/Model Bezzle/Canvas Web/Sources Web/prepare.sh Web/site/openfonts Packages/Vectorizer \
  | $here/win "New-Item -ItemType Directory -Force '$dest' | Out-Null; tar -x -f - -C '$dest'"
