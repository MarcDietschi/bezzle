#!/bin/zsh
# Sends the subject matte that Remove Background runs on Windows into the Bezzle test VM, where
# build.ps1 and the installer find it: Windows\Packages\subject-matte\BiRefNet.onnx under C:\src\Bezzle,
# or under the folder given. It is made on a Mac by Scripts/subject-matte/make-onnx.sh, into
# Scripts/subject-matte/build/onnx (git-ignored: GitHub takes no file of 471 MB), in this checkout
# or, from a git worktree, in the checkout it belongs to. Windows/onnx.ps1 says whether what
# arrived is the model measured.
#
#   Windows/VM/send-matte.sh [C:\src\<folder>]
set -euo pipefail
here=${0:A:h}
folder=${1:-'C:\src\Bezzle'}
repo=${here:h:h}
model=$repo/Scripts/subject-matte/build/onnx/BiRefNet.onnx
if [[ ! -f $model ]]; then
  # A worktree's git folder lies inside the main checkout's.
  main=$(git -C $repo rev-parse --path-format=absolute --git-common-dir)
  model=${main:h}/Scripts/subject-matte/build/onnx/BiRefNet.onnx
fi
[[ -f $model ]] || { print -u2 "No $model: make it with Scripts/subject-matte/make-onnx.sh first"; exit 1; }
print -r "Sending $model ($(( $(stat -f %z $model) / 1000000 )) MB) to $folder\\Windows\\Packages\\subject-matte"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -C ${model:h} -cf - BiRefNet.onnx \
  | $here/win "New-Item -ItemType Directory -Force '$folder\\Windows\\Packages\\subject-matte' | Out-Null; tar -x -f - -C '$folder\\Windows\\Packages\\subject-matte'"
