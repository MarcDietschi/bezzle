#!/bin/zsh
# Draws designs in depth (DepthTruthTests.swift here: groups that keep their layers' depth beside
# the same groups as one card, several layers turned as one body, artboards looked at from the side
# beside the same from the front, and films of them) with the Mac's renderer, then with
# bezzle-render in the Bezzle test VM, and says how far apart the pictures are:
#
#   Windows/VM/depth-agreement.sh [C:\src\<folder>] [out folder]
#
# The folder in the VM (C:\src\Bezzle unless named) is one sync.sh filled and build.ps1 built. The
# Mac's pictures are made by the truth test, copied into BezzleTests for that long and run alone
# (its build goes to <out>/dd, or the folder DEPTH_DD names); pictures already in <out>/mac are
# kept. The VM gets the designs in <folder>\depth-truth, which is taken away again. Back here come
# Windows' pictures and what bezzle-render said (<out>/windows), per picture the largest difference
# of a channel, the mean, and the share of channels more than 2 and 8 apart, of 255
# (<out>/agreement.txt), and the differences magnified eight times (<out>/differences). The
# pictures of a group as one card and of an artboard from the front are what Windows drew before
# any of this: what the others may be held against.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
folder=${1:-'C:\src\Bezzle'}
out=${2:-$(mktemp -d -t depth-agreement)}
mkdir -p $out

if [[ ! -d $out/mac/Depth.bezzle ]]; then
  cp $here/DepthTruthTests.swift $root/BezzleTests/DepthTruthTests.swift
  trap 'rm -f $root/BezzleTests/DepthTruthTests.swift' EXIT
  rm -rf $out/mac $out/mac.xcresult
  TEST_RUNNER_DEPTH_TRUTH_OUT=$out/mac DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
    -project $root/Bezzle.xcodeproj -scheme Bezzle -destination 'platform=macOS' -derivedDataPath ${DEPTH_DD:-$out/dd} \
    -resultBundlePath $out/mac.xcresult -parallel-testing-enabled NO -only-testing:BezzleTests/DepthTruthTests -quiet > $out/mac.log 2>&1 \
    || { echo "The Mac's pictures were not made: see $out/mac.log and $out/mac.xcresult"; exit 1 }
  rm -f $root/BezzleTests/DepthTruthTests.swift
  trap - EXIT
fi

truth="$folder\\depth-truth"
render="$folder\\Windows\\.build\\Bezzle\\bezzle-render.exe"
fonts="$folder\\Web\\site\\openfonts"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -c -C $out/mac -f - Depth.bezzle DepthFilm.bezzle \
  | $here/win "Remove-Item -Recurse -Force '$truth' -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force '$truth\\windows' | Out-Null; tar -x -f - -C '$truth'"
draw() {  # <what it is looked at from, or film moments> <design> <folder>
  $here/win "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $1; & '$render' '$fonts' '$truth\\$2.bezzle' '$truth\\windows\\$3' 2 | Out-File -Encoding utf8 '$truth\\windows\\$3.txt'"
}
draw "\$env:BEZZLE_NO_MCP='1'" Depth front
draw "\$env:BEZZLE_LOOK='-45,0'" Depth side-45_0
draw "\$env:BEZZLE_LOOK='30,40'" Depth side30_40
draw "\$env:BEZZLE_FILM_AT='0;0.5;1;1.5;2'" DepthFilm films

remote=${folder//\\//}
rm -rf $out/windows
scp -q -r -i ~/.ssh/bezzle-windows-vm -o IdentitiesOnly=yes -o UserKnownHostsFile=~/.ssh/bezzle-windows-vm.known_hosts \
  "bezzle@192.168.77.10:$remote/depth-truth/windows" $out/
$here/win "Remove-Item -Recurse -Force '$truth'"

rm -rf $out/differences
{
  for part in front side-45_0 side30_40 films; do
    echo "== $part"
    $here/depth-compare.py $out/mac/$part $out/windows/$part $out/differences/$part | column -t -s $'\t'
  done
  echo "== the part of the canvas each artboard's picture covers from the side: the Mac's (x, y, width, height), then Windows'"
  python3 -c 'import json, sys
for name, rects in sorted(json.load(open(sys.argv[1])).items()): print(name, rects)' $out/mac/covers.json
  grep -h covering $out/windows/side-45_0.txt $out/windows/side30_40.txt
} | tee $out/agreement.txt
echo "In $out"
