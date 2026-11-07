#!/bin/zsh
# Makes the Bezzle test VM: Windows 11 for Arm in UTM on this Mac, installed with no questions
# asked, reachable over SSH as `Windows/VM/win` once it is done (about 30 minutes).
#
#   Windows/VM/make-vm.sh [Win11_..._Arm64.iso]
#
# The image comes from https://www.microsoft.com/software-download/windows11arm64 (multi-edition,
# English; it comes as en-GB); by default the newest Windows 11 Arm64 .iso in Downloads. Needs
# `brew install wimlib xorriso`. The VM never needs its window, and its firmware's console is on
# its serial port (UTM shows the pty). Windows is not activated: it installs with Microsoft's
# generic Pro key, which is enough for building and testing.
#
# Kept outside the repository: the SSH key ~/.ssh/bezzle-windows-vm, the account's password
# ~/.ssh/bezzle-windows-vm.password (user "bezzle"), and the disks in ~/Library/Caches/bezzle-windows.

set -euo pipefail
here=${0:A:h}
name="Bezzle Windows"
cache=~/Library/Caches/bezzle-windows
key=~/.ssh/bezzle-windows-vm
address=192.168.77.10      # the VM's address, fixed in Windows (setup.ps1); the Mac is .1 on this network
mac=02:be:22:1e:00:01

iso=${1:-$(ls -t ~/Downloads/Win*11*[Aa]rm64*.iso 2>/dev/null | head -1)}
[[ -f $iso ]] || { echo "No Windows 11 for Arm image; download it first (see the top of $0)." >&2; exit 1; }
[[ -d /Applications/UTM.app ]] || brew install --cask utm
command -v wimlib-imagex >/dev/null && command -v xorriso >/dev/null || brew install wimlib xorriso
mkdir -p $cache
[[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -C bezzle-windows-vm -f $key
[[ -f $key.password ]] || (umask 077; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > $key.password)

# utmctl may not send UTM Apple events from here (-10004); osascript may.
open -g -a UTM
if osascript -e "tell application \"UTM\" to exists virtual machine \"$name\"" | grep -q true; then
    echo "UTM already has a VM named \"$name\"; delete it first to make it again." >&2; exit 1
fi

work=$(mktemp -d $cache/work.XXXX)
trap 'hdiutil detach -quiet $work/win 2>/dev/null; hdiutil detach -quiet $work/tools 2>/dev/null; chmod -R u+w $work; rm -rf $work' EXIT

# 1. The Windows disk, booting straight into setup: Microsoft's own files, with the EFI boot
#    image that does not wait for "Press any key to boot from CD or DVD", and the install archive
#    (7 GB) in parts under 4 GB, which setup reads as well and ISO 9660 can hold. (hdiutil's El
#    Torito image reads as empty in UTM's firmware, and Windows' boot loader started from the
#    image's UDF instead finds no boot settings.)
echo "Windows disk…"
mkdir $work/win $work/disk
hdiutil attach -quiet -nobrowse -readonly -mountpoint $work/win "$iso"
rsync -a --exclude /sources/install.wim $work/win/ $work/disk/
chmod -R u+w $work/disk
wimlib-imagex split $work/win/sources/install.wim $work/disk/sources/install.swm 3800 >/dev/null
hdiutil detach -quiet $work/win
xorriso -as mkisofs -quiet -iso-level 3 -J -joliet-long -V WIN11ARM \
    -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot -o $cache/windows.iso $work/disk
rm -rf $work/disk

# 2. The setup disk: the answer file, setup.ps1, the Mac's SSH key and UTM's drivers and tools.
echo "Setup disk…"
[[ -f $cache/utm-guest-tools.iso ]] || curl -fsSL -o $cache/utm-guest-tools.iso https://getutm.app/downloads/utm-guest-tools-latest.iso
mkdir -p $work/tools $work/setup
hdiutil attach -quiet -nobrowse -readonly -mountpoint $work/tools $cache/utm-guest-tools.iso
cp -R $work/tools/Drivers $work/tools/utm-guest-tools-*.exe $work/setup/
hdiutil detach -quiet $work/tools
PASSWORD=$(<$key.password) perl -pe 's/\@PASSWORD\@/$ENV{PASSWORD}/g' $here/autounattend.xml > $work/setup/autounattend.xml
cp $here/setup.ps1 $work/setup/
cp $key.pub $work/setup/authorized_keys
touch $work/setup/bezzle-setup.marker
hdiutil makehybrid -quiet -ov -o $cache/setup.iso -iso -joliet -default-volume-name BEZZLESETUP $work/setup

# 3. The VM. The empty system disk comes first in the boot order, so the firmware passes it by
#    until Windows is on it, and the Windows disk can stay in the drive afterwards.
echo "VM…"
open -g -a UTM
osascript - "$name" $cache/windows.iso $cache/setup.iso $mac $address <<'EOF'
on run argv
    set {vmName, winIso, setupIso, mac, addr} to argv
    tell application "UTM"
        set vm to make new virtual machine with properties {backend:qemu, configuration:{name:vmName, architecture:"aarch64", memory:12288, cpu cores:8, hypervisor:true, uefi:true, drives:{{guest size:131072, interface:NVMe}, {removable:true, interface:USB, source:(POSIX file winIso)}, {removable:true, interface:USB, source:(POSIX file setupIso)}}, network interfaces:{{mode:shared, address:mac, vlan guest address:"192.168.77.0/24", vlan dhcp start address:"192.168.77.1", vlan dhcp end address:"192.168.77.9"}}, displays:{{hardware:"virtio-ramfb", dynamic resolution:true}}}}
        return id of vm
    end tell
end run
EOF

osascript -e "tell application \"UTM\" to start virtual machine \"$name\""
echo "Installing Windows in \"$name\". When \`$here/win hostname\` answers, it is ready."
