#!/bin/zsh
# Sends the subject matte that Remove Background runs on Windows into the Bezzle test VM, where
# build.ps1 and the installer find it: Windows\Packages\subject-matte under C:\src\Bezzle, or under
# the folder given. It is three files, the graphs of the two sizes and the weights both read
# (BiRefNet-2048.onnx, BiRefNet-1024.onnx, BiRefNet.weights), made on a Mac by
# Scripts/subject-matte/make-onnx.sh into Scripts/subject-matte/build/onnx (git-ignored: GitHub
# takes no file over 100 MB), in this checkout or, from a git worktree, in the checkout it belongs
# to. Windows/onnx.ps1 says whether what arrived is the model measured.
#
#   Windows/VM/send-matte.sh [C:\src\<folder>]
set -euo pipefail
here=${0:A:h}
folder=${1:-'C:\src\Bezzle'}
repo=${here:h:h}
files=(BiRefNet-2048.onnx BiRefNet-1024.onnx BiRefNet.weights)
from=$repo/Scripts/subject-matte/build/onnx
if [[ ! -f $from/$files[1] ]]; then
  # A worktree's git folder lies inside the main checkout's.
  main=$(git -C $repo rev-parse --path-format=absolute --git-common-dir)
  from=${main:h}/Scripts/subject-matte/build/onnx
fi
size=0
for file in $files; do
  [[ -f $from/$file ]] || { print -u2 "No $from/$file: make it with Scripts/subject-matte/make-onnx.sh first"; exit 1; }
  (( size += $(stat -f %z $from/$file) ))
done
print -r "Sending $files from $from ($(( size / 1000000 )) MB) to $folder\\Windows\\Packages\\subject-matte"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -C $from -cf - $files \
  | $here/win "New-Item -ItemType Directory -Force '$folder\\Windows\\Packages\\subject-matte' | Out-Null; tar -x -f - -C '$folder\\Windows\\Packages\\subject-matte'"
