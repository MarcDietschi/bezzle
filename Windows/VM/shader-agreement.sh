#!/bin/zsh
# Draws the shader engine's agreement samples (Packages/Shaders/Tests/ShadersTests/AgreementTests.swift)
# with Metal on this Mac, then with Direct3D in the Bezzle test VM, and says how far apart they are:
#
#   Windows/VM/shader-agreement.sh [C:\src\<folder>] [out folder]
#
# The folder in the VM (C:\src\Bezzle unless named) is one sync.sh fills; the engine is sent into it
# anew. The VM runs every test of the package, the comparison among them, with two jobs. Back here
# come agreement.txt (per sample the largest difference of a channel, the mean, and the share of
# channels more than 2 and 8 apart, of 255) and, per sample, what Direct3D drew and the difference
# magnified eight times, beside the Metal references.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
folder=${1:-'C:\src\Bezzle'}
out=${2:-$(mktemp -d -t shader-agreement)}
mkdir -p $out/references $out/compared
cd $root/Packages/Shaders
SHADERS_WRITE_REFERENCES=$out/references DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path $out/build --filter AgreementTests >/dev/null 2>&1
cd $root
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -ch --exclude .build -f - Packages/Shaders \
  | $here/win "Remove-Item -Recurse -Force '$folder\\Packages\\Shaders\\Sources', '$folder\\Packages\\Shaders\\Tests' -ErrorAction SilentlyContinue; tar -x -f - -C '$folder'"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -c -C $out -f - references \
  | $here/win "Remove-Item -Recurse -Force '$folder\\shader-references', '$folder\\shader-compared' -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force '$folder\\shader-references' | Out-Null; tar -x -f - -C '$folder\\shader-references' --strip-components 1"
$here/win "cd '$folder\\Packages\\Shaders'; \$env:SHADERS_REFERENCES='$folder\\shader-references'; \$env:SHADERS_COMPARED='$folder\\shader-compared'; swift test -j 2 2>&1 | Select-String -Pattern 'recorded an issue|Test run with' | ForEach-Object { \$_.Line }" || true
remote=${folder//\\//}
scp -q -i ~/.ssh/bezzle-windows-vm -o IdentitiesOnly=yes -o UserKnownHostsFile=~/.ssh/bezzle-windows-vm.known_hosts \
  "bezzle@192.168.77.10:$remote/shader-compared/*" $out/compared/
column -t -s $'\t' $out/compared/agreement.txt
echo "In $out"
