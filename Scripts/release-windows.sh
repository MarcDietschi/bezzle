#!/bin/bash
# Releases Bezzle for Windows on its website, as Scripts/release.sh does the Mac's. Builds the commit
# that is checked out in the Windows VM (Windows/VM), for x64 and Arm64, makes their installers
# (Windows/Installer: per user, no administrator, with the Windows App Runtime and the updater),
# signs them with Sparkle's EdDSA key, the one the Mac's updates are signed with, and writes the
# update feed with the notes from RELEASE_NOTES.md. Unsigned by Microsoft's measure: Windows asks
# once whether to run an app from an unknown publisher (Erik, 2026-11-07: no paid certificate).
#
# Usage: Scripts/release-windows.sh [--publish] [--arch "x64 arm64"] [--out <folder>]
#
# Without --publish it is a dry run, and publishes nothing: the installers and the feed go to the
# Desktop (or --out), the feed signed with a throwaway key (so it could never update anyone), the
# installers made as the release makes them, with the real feed's address and public key in them.
# With --publish it then
#   1. attaches the installers to the GitHub release windows-v<version> of mfrports/bezzle-web
#      (Bezzle-<version>-Setup-x64.exe and -arm64.exe),
#   2. commits the feed there as public/updates/windows/appcast.xml (and RELEASE_NOTES.md, as the
#      Mac's release does), whose Deploy workflow fetches every enclosure under
#      https://bezzle.ch/downloads/ from that GitHub release, checks its length and puts it up,
#   3. waits until https://bezzle.ch/updates/windows/appcast.xml offers the version and its
#      installers answer, and tags the commit windows-v<version>, which marks it as released.
#
# The version is the Mac's, as set in Xcode (MARKETING_VERSION), and its notes the Mac's entry in
# RELEASE_NOTES.md (CLAUDE.md › Releases). A version both have shipped can go out on Windows later.
#
# Needs:
# - the Windows VM running (Windows/VM/make-vm.sh), with the shared packages built in
#   C:\src\Bezzle\Windows\Packages (winrt.ps1, skia.ps1, avif.ps1) and an x64 build set up there,
#   and Remove Background's subject matte sent there once (Windows/VM/send-matte.sh, after
#   Scripts/subject-matte/make-onnx.sh); release.ps1 fetches ONNX Runtime and DirectML (onnx.ps1)
# - Web/site/openfonts (Web/tools/openfonts.py), git-ignored, as the VM sync takes it
# - for --publish: the commit pushed to origin/main; Sparkle's EdDSA key in the login Keychain (or
#   as a file in BEZZLE_SPARKLE_KEY_FILE); gh, signed in with push access to mfrports/bezzle-web
set -euo pipefail

PUBLISH=""
ARCHS="x64 arm64"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --dry-run) PUBLISH=""; shift ;;
    --arch) ARCHS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "usage: Scripts/release-windows.sh [--publish] [--arch \"x64 arm64\"] [--out <folder>]" >&2; exit 1 ;;
  esac
done
fail() { echo "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SITE_REPO=mfrports/bezzle-web
SITE=https://bezzle.ch
# Written into every installed copy: never moves.
FEED_URL="$SITE/updates/windows/appcast.xml"
# Where the site's Deploy puts the installers it fetches from the GitHub release.
DOWNLOADS="$SITE/downloads/"
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_PUBLIC_KEY=gvpXvDhAL5jDyaSz0Vm5FtB2O/PKY1NRdNqSKR8cldU=
CACHE="${BEZZLE_RELEASE_CACHE:-$HOME/Library/Caches/bezzle-release}"
# The VM, and the folder there the release is built in, beside the others' (its .build is kept, so
# a release after another builds only what changed).
VM="$ROOT/Windows/VM/win"
VM_DIR="${BEZZLE_WINDOWS_RELEASE_DIR:-C:\\src\\bezzle-release}"
VM_CACHE="${BEZZLE_WINDOWS_RELEASE_CACHE:-C:\\bezzle\\release-cache}"
VM_SSH=(-i ~/.ssh/bezzle-windows-vm -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/bezzle-windows-vm.known_hosts -o ConnectTimeout=5)

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
VERSION="$(git -C "$ROOT" show "$COMMIT:Bezzle.xcodeproj/project.pbxproj" | sed -nE 's/^[[:space:]]*MARKETING_VERSION = "?([^";]+)"?;$/\1/p' | sort -u)"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "The Xcode project should carry one version (MARKETING_VERSION), found: ${VERSION:-none}"
TAG="windows-v$VERSION"
# Compared by WinSparkle part by part, each a 32-bit number: the date, then the time.
BUILD="$(date +%Y%m%d.%H%M)"
echo "Bezzle $VERSION for Windows ($BUILD, $ARCHS) from $(git -C "$ROOT" log -1 --format='%h %s' "$COMMIT")"
CHANGED="$(git -C "$ROOT" status --porcelain -- Windows Bezzle Web/Sources Web/prepare.sh RELEASE_NOTES.md Scripts/release Scripts/release-windows.sh)"
[ -z "$CHANGED" ] || printf 'Not in this release, since not committed:\n%s\n' "$CHANGED"
for ARCH in $ARCHS; do [[ "$ARCH" == x64 || "$ARCH" == arm64 ]] || fail "No architecture $ARCH: x64 or arm64"; done
[ -f "$ROOT/Web/site/openfonts/manifest.json" ] || fail "Web/site/openfonts is missing: make it with Web/tools/openfonts.py"
"$VM" 'exit 0' || fail "The Windows VM does not answer (Windows/VM/win)"

if [ -n "$PUBLISH" ]; then
  [[ " $ARCHS " == *" x64 "* && " $ARCHS " == *" arm64 "* ]] || fail "A release offers both x64 and arm64 (the site's default is x64)"
  command -v gh >/dev/null || fail "gh is missing: brew install gh, then gh auth login"
  git -C "$ROOT" fetch -q origin main
  git -C "$ROOT" merge-base --is-ancestor "$COMMIT" origin/main || fail "Push $COMMIT to origin/main first: a release is made from what is pushed"
  git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 \
    && fail "$TAG is released already: raise the version in Xcode for a new release"
  gh release view "$TAG" -R "$SITE_REPO" >/dev/null 2>&1 \
    && fail "github.com/$SITE_REPO has a release $TAG, but the app has no tag for it: a run that failed half way? Delete it with gh release delete $TAG -R $SITE_REPO --cleanup-tag --yes, then run again"
  curl -fsS "$FEED_URL?check=$(date +%s)" 2>/dev/null | grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" \
    && fail "The live Windows feed offers $VERSION already"
fi

# Sparkle's sign_update, as released by its makers (the Mac's release fetches the same).
SPARKLE_DIR="$CACHE/sparkle-$SPARKLE_VERSION"
if [ ! -x "$SPARKLE_DIR/bin/sign_update" ]; then
  echo "Fetching Sparkle ${SPARKLE_VERSION}…"
  mkdir -p "$CACHE"
  TAR="$CACHE/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL --retry 3 -o "$TAR" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  [ "$(shasum -a 256 "$TAR" | cut -d' ' -f1)" = "$SPARKLE_SHA256" ] || { rm -f "$TAR"; fail "The Sparkle download is not the one pinned in this script"; }
  rm -rf "$SPARKLE_DIR.part" && mkdir -p "$SPARKLE_DIR.part"
  tar -xJf "$TAR" -C "$SPARKLE_DIR.part" && mv "$SPARKLE_DIR.part" "$SPARKLE_DIR" && rm -f "$TAR"
fi

mkdir -p "$CACHE"
WORK="$(mktemp -d "$CACHE/windows-run.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SIGN=("$SPARKLE_DIR/bin/sign_update")
if [ -n "$PUBLISH" ]; then
  if [ -n "${BEZZLE_SPARKLE_KEY_FILE:-}" ]; then
    SIGN+=(--ed-key-file "$BEZZLE_SPARKLE_KEY_FILE")
  else
    # The Keychain may ask once whether Sparkle's tools may use the key: allow it always.
    [ "$("$SPARKLE_DIR/bin/generate_keys" -p 2>/dev/null || true)" = "$SPARKLE_PUBLIC_KEY" ] \
      || fail "The login Keychain has no Sparkle key whose public half is $SPARKLE_PUBLIC_KEY: without it, no copy would take the update"
  fi
else
  # A dry run signs with a key of its own, made now and thrown away with the run.
  cat > "$WORK/key.swift" <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
SWIFT
  xcrun swift "$WORK/key.swift" > "$WORK/throwaway.key"
  SIGN+=(--ed-key-file "$WORK/throwaway.key")
fi

# The commit, not the working tree: what the VM builds, with what is made from it on the Mac (the
# Mac's pointers, words and icons, the web core's generated files) and the open fonts.
SRC="$WORK/src"
mkdir -p "$SRC"
git -C "$ROOT" archive "$COMMIT" -- Windows Bezzle Web/Sources Web/prepare.sh RELEASE_NOTES.md Scripts/release | tar -x -C "$SRC"
if [ -n "$PUBLISH" ]; then
  python3 "$SRC/Scripts/release/notes.py" check "$VERSION"
else
  python3 "$SRC/Scripts/release/notes.py" check "$VERSION" || echo "(A dry run goes on without them.)"
fi
zsh "$SRC/Web/prepare.sh"
"$SRC/Windows/Resources/make-cursors.sh" >/dev/null
python3 "$SRC/Windows/Resources/make-strings.py" >/dev/null
"$SRC/Windows/Resources/make-icons.sh" >/dev/null
echo "$VERSION" > "$SRC/Windows/Resources/Generated/version.txt"
mkdir -p "$SRC/Web/site"
cp -R "$ROOT/Web/site/openfonts" "$SRC/Web/site/openfonts"

echo "Copying it into the VM ($VM_DIR)…"
# The sources anew (a file the commit no longer has must not stay), the build kept.
"$VM" "New-Item -ItemType Directory -Force '$VM_DIR' | Out-Null; foreach (\$d in 'Windows\\Sources','Windows\\Installer','Windows\\Credits','Windows\\Resources','Bezzle','Web') { if (Test-Path \"$VM_DIR\\\$d\") { Remove-Item -Recurse -Force \"$VM_DIR\\\$d\" } }"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -ch -C "$SRC" --exclude 'Web/out' -f - Windows Bezzle/Model Bezzle/Canvas Web/Sources Web/prepare.sh Web/site/openfonts \
  | "$VM" "tar -x -f - -C '$VM_DIR'"

echo "Building and making the installers in the VM (some minutes per architecture)…"
ARCH_LIST="$(echo $ARCHS | tr ' ' ',')"
"$VM" "& '$VM_DIR\\Windows\\Installer\\release.ps1' -Version $VERSION -Build $BUILD -Archs $ARCH_LIST -Feed '$FEED_URL' -PublicKey '$SPARKLE_PUBLIC_KEY' -Cache '$VM_CACHE'" | tee "$WORK/vm.log"
grep -q '^{"Installer"' "$WORK/vm.log" || fail "The VM made no installer (above)"

# The installers back on the Mac, with the symbols of each Bezzle.exe kept for reading crashes.
SYMBOLS="$CACHE/windows-symbols"
mkdir -p "$WORK/out" "$SYMBOLS"
ENCLOSURES=()
for ARCH in $ARCHS; do
  LINE="$(grep "Setup-$ARCH.exe" "$WORK/vm.log" | grep '^{"Installer"' | tail -1)"
  [ -n "$LINE" ] || fail "No installer for $ARCH"
  REMOTE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["Installer"])' "$LINE")"
  SHA="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["SHA256"])' "$LINE")"
  PDB="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["Symbols"])' "$LINE")"
  FILE="$WORK/out/Bezzle-$VERSION-Setup-$ARCH.exe"
  scp -q "${VM_SSH[@]}" "bezzle@192.168.77.10:${REMOTE//\\//}" "$FILE"
  scp -q "${VM_SSH[@]}" "bezzle@192.168.77.10:${PDB//\\//}" "$SYMBOLS/"
  [ "$(shasum -a 256 "$FILE" | cut -d' ' -f1)" = "$SHA" ] || fail "$FILE did not arrive whole"
  SIGNED="$("${SIGN[@]}" "$FILE")"
  SIGNATURE="$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<<"$SIGNED")"
  [ -n "$SIGNATURE" ] || fail "sign_update gave no signature for $FILE"
  ENCLOSURES+=("$ARCH=$FILE=$SIGNATURE")
  echo "  $(basename "$FILE"): $(du -h "$FILE" | cut -f1)"
done
python3 "$SRC/Scripts/release/windows-feed.py" "$WORK/out/appcast.xml" "$VERSION" "$BUILD" "$DOWNLOADS" "${ENCLOSURES[@]}"

if [ -z "$PUBLISH" ]; then
  OUT="${OUT:-$HOME/Desktop/Bezzle $VERSION for Windows ($BUILD)}"
  mkdir -p "$OUT"
  cp "$WORK/out/"* "$OUT/"
  python3 "$SRC/Scripts/release/notes.py" github "$VERSION" > "$OUT/release-notes.md" 2>/dev/null || true
  echo "Dry run: the installers and the feed (signed with a throwaway key) are in $OUT. Nothing was published."
  exit 0
fi

echo "Publishing the GitHub release ${TAG}…"
python3 "$SRC/Scripts/release/notes.py" github "$VERSION" > "$WORK/notes.md"
gh release create "$TAG" -R "$SITE_REPO" --title "Bezzle $VERSION for Windows" --notes-file "$WORK/notes.md" "$WORK/out/"*.exe
for ARCH in $ARCHS; do
  NAME="Bezzle-$VERSION-Setup-$ARCH.exe"
  DOWNLOAD="https://github.com/$SITE_REPO/releases/download/$TAG/$NAME"
  # One byte of it, through GitHub's redirect; the total length comes with it.
  LENGTH="$(curl -sSL -r 0-0 -D - -o /dev/null "$DOWNLOAD" | tr -d '\r' | sed -nE 's#^[Cc]ontent-[Rr]ange: bytes 0-0/([0-9]+)$#\1#p' | tail -1)"
  [ "$LENGTH" = "$(stat -f %z "$WORK/out/$NAME")" ] || fail "$DOWNLOAD does not answer with the installer (length ${LENGTH:-none})"
done

# Only now the feed: the site's Deploy fetches the installers it names from the release above.
echo "Publishing the feed on the website…"
gh repo clone "$SITE_REPO" "$WORK/site" -- --depth 1 -q
mkdir -p "$WORK/site/public/updates/windows" "$WORK/site/src/releases"
cp "$WORK/out/appcast.xml" "$WORK/site/public/updates/windows/appcast.xml"
cp "$SRC/RELEASE_NOTES.md" "$WORK/site/src/releases/RELEASE_NOTES.md"
if [ -f "$WORK/site/package.json" ]; then
  command -v npm >/dev/null || fail "npm is needed to check that the website builds (brew install node): nothing was pushed to it"
  if ! (cd "$WORK/site" && npm ci --no-audit --no-fund --loglevel=error && npm run build --silent) > "$CACHE/site-build.log" 2>&1; then
    fail "The website does not build with the new feed ($CACHE/site-build.log): nothing was pushed to it. The GitHub release $TAG stays; delete it with gh release delete $TAG -R $SITE_REPO --cleanup-tag --yes"
  fi
fi
git -C "$WORK/site" add public/updates/windows/appcast.xml src/releases/RELEASE_NOTES.md
git -C "$WORK/site" commit -q -m "Bezzle $VERSION for Windows" -m "The Windows update feed, from the app's Scripts/release-windows.sh."
git -C "$WORK/site" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q origin HEAD:main

echo "Waiting for the website…"
live() {
  curl -fsS "$FEED_URL?check=$(date +%s)" 2>/dev/null | grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" || return 1
  for ARCH in $ARCHS; do
    NAME="Bezzle-$VERSION-Setup-$ARCH.exe"
    [ "$(curl -sSL -r 0-0 -D - -o /dev/null "$DOWNLOADS$NAME" | tr -d '\r' | sed -nE 's#^[Cc]ontent-[Rr]ange: bytes 0-0/([0-9]+)$#\1#p' | tail -1)" = "$(stat -f %z "$WORK/out/$NAME")" ] || return 1
  done
}
LIVE=""
for _ in $(seq 1 60); do
  if live; then LIVE=1; break; fi
  sleep 10
done
[ -n "$LIVE" ] || fail "After 10 minutes $FEED_URL does not offer $VERSION with its installers: see the Deploy workflow at https://github.com/$SITE_REPO/actions. Once it does, tag the commit: git tag $TAG $COMMIT && git push origin refs/tags/$TAG"

git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git -C "$ROOT" tag "$TAG" "$COMMIT"
git -C "$ROOT" push -q origin "refs/tags/$TAG"
echo "Bezzle $VERSION for Windows is live: $SITE/download.html"
echo "Tagged $TAG. Pull ~/Sites/bezzle-web before changing the site."
