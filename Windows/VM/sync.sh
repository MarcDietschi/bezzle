#!/bin/zsh
# Copies the working tree's Windows build inputs into the Bezzle test VM, at C:\src\Bezzle or the
# folder given (a second working copy's, `sync.sh 'C:\src\<folder>'`, which then gets a junction to
# C:\src\Bezzle\Windows\Packages): Windows/, and what it shares with the Mac app and the web core,
# the Vectorize engine (Packages/Vectorizer) and the shader engine (Packages/Shaders) among it.
# Symlinks arrive as the files they point at. Leaves Windows\Packages and .build there alone.
set -euo pipefail
here=${0:A:h}
dest=${1:-'C:\src\Bezzle'}
cd ${here:h:h}
# The shared files the web core makes with a line changed (Web/prepare.sh), made anew: the VM keeps
# what was sent before, so without this a Windows build compiles them as they were.
Web/prepare.sh
# The Mac's pointers, as cursors for the Windows build to put into Bezzle.exe.
$here/../Resources/make-cursors.sh
# The Mac's words in German, French and Italian, for the Windows build to put beside Bezzle.exe.
$here/../Resources/make-strings.py
# The Mac's app and document icons, for the installer to put into Bezzle.exe.
$here/../Resources/make-icons.sh
# The Mac's version (Xcode's MARKETING_VERSION), which a copy built in the VM says it is.
sed -nE 's/^[[:space:]]*MARKETING_VERSION = "?([^";]+)"?;$/\1/p' Bezzle.xcodeproj/project.pbxproj | sort -u | head -1 \
  > $here/../Resources/Generated/version.txt
# The welcome tour's lake photo and its logo to trace, painted as the Mac paints them, for the build
# to put into Bezzle.resources.
$here/../Resources/make-welcome-photo.sh
junction=''
if [[ $dest != 'C:\src\Bezzle' ]]; then
  junction="if (-not (Test-Path '$dest\\Windows\\Packages')) { New-Item -ItemType Junction -Path '$dest\\Windows\\Packages' -Target 'C:\\src\\Bezzle\\Windows\\Packages' | Out-Null }"
fi
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -ch --exclude .build --exclude Windows/Packages --exclude node_modules --exclude 'Web/out' \
    -f - Windows Bezzle/Model Bezzle/Canvas Web/Sources Web/prepare.sh Web/site/openfonts Packages/Vectorizer Packages/Shaders \
  | $here/win "New-Item -ItemType Directory -Force '$dest\\Windows' | Out-Null; $junction; tar -x -f - -C '$dest'"
