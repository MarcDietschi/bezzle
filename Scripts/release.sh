#!/bin/bash
# Releases Bezzle on its website, beside the Mac App Store. Builds the commit that is checked out as the
# copy that updates itself (BEZZLE_DIRECT, see Bezzle/App/Updates.swift), puts Sparkle into it, signs it
# with the Developer ID, has Apple notarize it, and publishes the zip, with delta updates from the last
# versions, as a GitHub release of mfrports/bezzle-web. Then it commits the new update feed and the release
# notes to that repository, whose Deploy workflow rebuilds the website with them, waits until the feed is
# live, and tags the commit v<version>.
#
# Usage: Scripts/release.sh [--dry-run]
# The version is the one set in Xcode (MARKETING_VERSION), the same the App Store gets: raise it there
# first, and write its entry in RELEASE_NOTES.md (CLAUDE.md › Releases). Both must be pushed.
# With --dry-run it stops once the notarized zip is on the Desktop and publishes nothing: the build to
# try on another Mac first.
#
# Needs:
# - the commit pushed to origin/main, and Bezzle/Canvas/BiRefNet.mlpackage (Scripts/subject-matte/make.sh)
# - a "Developer ID Application" certificate in the Keychain, and Xcode signed in to the team: the
#   export uses the Developer ID provisioning profile for com.erik.Bezzle, which carries iCloud
# - the notary credentials: the keychain profile BEZZLE_NOTARY_PROFILE (harness-notary, Gerty's, by
#   default), or ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER as for Scripts/appstore/publish.py
# - Sparkle's EdDSA key in the login Keychain, the one Gerty's releases sign with (one key serves every
#   app; its public half is SPARKLE_PUBLIC_KEY below), or as a file in BEZZLE_SPARKLE_KEY_FILE
# - gh, signed in with push access to mfrports/bezzle-web
set -euo pipefail

DRY_RUN=""
[ "${1:-}" = --dry-run ] && { DRY_RUN=1; shift; }
[ $# -eq 0 ] || { echo "usage: Scripts/release.sh [--dry-run]" >&2; exit 1; }
fail() { echo "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SITE_REPO=mfrports/bezzle-web
SITE=https://mfrports.github.io/bezzle-web
# The app's SUFeedURL: written into every copy, so it never moves.
FEED_URL="$SITE/updates/appcast.xml"
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_PUBLIC_KEY=gvpXvDhAL5jDyaSz0Vm5FtB2O/PKY1NRdNqSKR8cldU=
IDENTITY="${BEZZLE_SIGN_IDENTITY:-Developer ID Application}"
# Delta updates lead from this many of the last versions to the new one.
DELTAS_FROM="${BEZZLE_DELTAS_FROM:-3}"
# Outside ~/Documents, which iCloud syncs and where code signing breaks: Sparkle, the released zips
# the deltas are made from (fetched again from GitHub when missing), and each run's build.
CACHE="${BEZZLE_RELEASE_CACHE:-$HOME/Library/Caches/bezzle-release}"
DIST="$CACHE/dist"

# What is released is the commit, not the working tree, which other work may have changed.
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
VERSION="$(git -C "$ROOT" show "$COMMIT:Bezzle.xcodeproj/project.pbxproj" | sed -nE 's/^[[:space:]]*MARKETING_VERSION = "?([^";]+)"?;$/\1/p' | sort -u)"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "The Xcode project should carry one version (MARKETING_VERSION), found: ${VERSION:-none}"
echo "Bezzle $VERSION from $(git -C "$ROOT" log -1 --format='%h %s' "$COMMIT")"
CHANGED="$(git -C "$ROOT" status --porcelain -- Bezzle BezzleThumbnails Bezzle.xcodeproj Packages Info.plist Bezzle.entitlements RELEASE_NOTES.md Scripts/release)"
[ -z "$CHANGED" ] || printf 'Not in this release, since not committed:\n%s\n' "$CHANGED"

[ -d "$ROOT/Bezzle/Canvas/BiRefNet.mlpackage" ] || fail "Bezzle/Canvas/BiRefNet.mlpackage is missing: make it with Scripts/subject-matte/make.sh"
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || fail "No \"$IDENTITY\" certificate in the Keychain: create one in Xcode › Settings › Accounts › Manage Certificates"
if [ -n "${ASC_KEY_PATH:-}" ]; then
  [ -f "$ASC_KEY_PATH" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER:-}" ] || fail "ASC_KEY_PATH needs the key file, ASC_KEY_ID and ASC_ISSUER"
  NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER")
else
  NOTARY=(--keychain-profile "${BEZZLE_NOTARY_PROFILE:-harness-notary}")
fi
xcrun notarytool history "${NOTARY[@]}" >/dev/null 2>&1 || fail "The notary credentials are missing or no longer accepted (${NOTARY[*]})"

if [ -z "$DRY_RUN" ]; then
  command -v gh >/dev/null || fail "gh is missing: brew install gh, then gh auth login"
  git -C "$ROOT" fetch -q origin main
  git -C "$ROOT" merge-base --is-ancestor "$COMMIT" origin/main || fail "Push $COMMIT to origin/main first: a release is made from what is pushed"
  git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1 \
    && fail "v$VERSION is released already: raise the version in Xcode for a new release"
  gh release view "v$VERSION" -R "$SITE_REPO" >/dev/null 2>&1 \
    && fail "github.com/$SITE_REPO has a release v$VERSION, but the app has no tag for it: a run that failed half way? Delete it with gh release delete v$VERSION -R $SITE_REPO --cleanup-tag --yes, then run again"
  curl -fsS "$FEED_URL?check=$(date +%s)" 2>/dev/null | grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" \
    && fail "The live feed offers $VERSION already"
fi

# Sparkle, as released by its makers, checked against the download it was tried with.
SPARKLE_DIR="$CACHE/sparkle-$SPARKLE_VERSION"
if [ ! -x "$SPARKLE_DIR/bin/generate_appcast" ]; then
  echo "Fetching Sparkle ${SPARKLE_VERSION}…"
  mkdir -p "$CACHE"
  TAR="$CACHE/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL --retry 3 -o "$TAR" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  [ "$(shasum -a 256 "$TAR" | cut -d' ' -f1)" = "$SPARKLE_SHA256" ] || { rm -f "$TAR"; fail "The Sparkle download is not the one pinned in this script"; }
  rm -rf "$SPARKLE_DIR.part" && mkdir -p "$SPARKLE_DIR.part"
  tar -xJf "$TAR" -C "$SPARKLE_DIR.part" && mv "$SPARKLE_DIR.part" "$SPARKLE_DIR" && rm -f "$TAR"
fi
KEY_ARGS=()
if [ -z "$DRY_RUN" ]; then
  if [ -n "${BEZZLE_SPARKLE_KEY_FILE:-}" ]; then
    KEY_ARGS=(--ed-key-file "$BEZZLE_SPARKLE_KEY_FILE")
  else
    # The Keychain may ask once whether Sparkle's tools may use the key: allow it always.
    [ "$("$SPARKLE_DIR/bin/generate_keys" -p 2>/dev/null || true)" = "$SPARKLE_PUBLIC_KEY" ] \
      || fail "The login Keychain has no Sparkle key whose public half is $SPARKLE_PUBLIC_KEY: without it, no copy would take the update"
  fi
fi

mkdir -p "$CACHE"
WORK="$(mktemp -d "$CACHE/run.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"
mkdir -p "$SRC"
git -C "$ROOT" archive "$COMMIT" -- Bezzle BezzleThumbnails BezzleTests Bezzle.xcodeproj Packages Info.plist Bezzle.entitlements \
  RELEASE_NOTES.md Scripts/release | tar -x -C "$SRC"
# Too large for git: the subject matte comes from the working tree.
ditto "$ROOT/Bezzle/Canvas/BiRefNet.mlpackage" "$SRC/Bezzle/Canvas/BiRefNet.mlpackage"
if [ -z "$DRY_RUN" ]; then
  python3 "$SRC/Scripts/release/notes.py" check "$VERSION"
else
  python3 "$SRC/Scripts/release/notes.py" check "$VERSION" || echo "(A dry run goes on without them.)"
fi

# Sparkle decides what is newer by the build number, so every release gets a larger one.
BUILD="$(date +%Y%m%d%H%M)"
echo "Building Bezzle $VERSION ($BUILD), the copy for the website…"
xcodebuild archive -project "$SRC/Bezzle.xcodeproj" -scheme Bezzle -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$WORK/Bezzle.xcarchive" -derivedDataPath "$WORK/build" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BEZZLE_DIRECT' -quiet
echo "Exporting with the Developer ID…"
xcodebuild -exportArchive -archivePath "$WORK/Bezzle.xcarchive" -exportOptionsPlist "$SRC/Scripts/release/ExportOptions.plist" \
  -exportPath "$WORK/export" -allowProvisioningUpdates -quiet
APP="$WORK/export/Bezzle.app"
PLIST="$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
grep -aq SPUStandardUpdaterController "$APP/Contents/MacOS/Bezzle" || fail "This build has no updater: BEZZLE_DIRECT did not reach it"
[ -f "$APP/Contents/embedded.provisionprofile" ] || fail "The export holds no provisioning profile, so iCloud would not work"

# The export's entitlements, and what the copy from the website needs beyond the App Store's: production
# iCloud and push (the export usually sets them), and Sparkle's installer, which a sandboxed app reaches
# through these two services (sparkle-project.org/documentation/sandboxing). The App Store build never has them.
ENT="$WORK/Bezzle.entitlements"
codesign -d --entitlements - --xml "$APP" > "$ENT" 2>/dev/null
pb() { /usr/libexec/PlistBuddy -c "$1" "$ENT" 2>/dev/null; }
[ "$(pb 'Print :com.apple.security.app-sandbox')" = true ] || fail "The exported app is not sandboxed"
case "$(pb 'Print :com.apple.developer.icloud-container-environment' || echo none)" in
  Production) ;;
  none) pb 'Add :com.apple.developer.icloud-container-environment string Production' ;;
  *) fail "The export chose iCloud's $(pb 'Print :com.apple.developer.icloud-container-environment') environment" ;;
esac
pb 'Set :com.apple.developer.aps-environment production' || pb 'Add :com.apple.developer.aps-environment string production'
pb 'Delete :com.apple.security.temporary-exception.mach-lookup.global-name' || true
pb 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array'
pb "Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $BUNDLE_ID-spks"
pb "Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $BUNDLE_ID-spki"
# Where it looks for updates, the key they must be signed with, and to look and fetch without asking.
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" \
  -c "Add :SUEnableInstallerLauncherService bool true" -c "Add :SUEnableAutomaticChecks bool true" \
  -c "Add :SUAutomaticallyUpdate bool true" "$PLIST"

echo "Putting Sparkle in and signing as ${IDENTITY}…"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Innermost first; the app comes last because its signature seals all the others. The Quick Look
# extension keeps the signature the export gave it.
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"

echo "Notarizing: Apple usually answers within a few minutes…"
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
SUBMISSION="$(xcrun notarytool submit "$WORK/notarize.zip" "${NOTARY[@]}" --output-format json | plutil -extract id raw -o - -)"
xcrun notarytool wait "$SUBMISSION" "${NOTARY[@]}" >/dev/null || true
STATUS="$(xcrun notarytool info "$SUBMISSION" "${NOTARY[@]}" --output-format json | plutil -extract status raw -o - -)"
if [ "$STATUS" != Accepted ]; then
  echo "Apple did not notarize the app (${STATUS}). Its report:" >&2
  xcrun notarytool log "$SUBMISSION" "${NOTARY[@]}" >&2 || true
  exit 1
fi
# Stapled, the app proves its notarization even on a Mac that is offline.
xcrun stapler staple -q "$APP"
spctl -a -t exec -vv "$APP"

if [ -n "$DRY_RUN" ]; then
  OUT="$HOME/Desktop/Bezzle $VERSION ($BUILD).zip"
  ditto -c -k --keepParent "$APP" "$OUT"
  echo "Dry run: the notarized app is in $OUT ($(du -h "$OUT" | cut -f1)). Nothing was published."
  exit 0
fi

# The released versions the deltas lead from: kept in dist/, fetched from their GitHub release when missing.
# The feed and the deltas are made fresh each time; an older feed would keep stale items.
mkdir -p "$DIST"
rm -rf "$DIST/appcast.xml" "$DIST/old_updates" "$DIST"/*.delta
PREVIOUS="$(gh release list -R "$SITE_REPO" --limit 100 --json tagName,isDraft --jq '.[] | select(.isDraft | not) | .tagName' \
  | sed -nE 's/^v([0-9]+(\.[0-9]+){0,2})$/\1/p' | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -n "$DELTAS_FROM")"
for OLD in "$DIST"/Bezzle-*.zip; do
  [ -e "$OLD" ] || continue
  V="$(basename "$OLD" .zip)"; V="${V#Bezzle-}"
  grep -qxF "$V" <<<"$PREVIOUS" || rm -f "$OLD"
done
for V in $PREVIOUS; do
  [ -s "$DIST/Bezzle-$V.zip" ] && continue
  echo "Fetching Bezzle $V for the delta update…"
  gh release download "v$V" -R "$SITE_REPO" -p "Bezzle-$V.zip" -D "$DIST" --clobber || { rm -f "$DIST/Bezzle-$V.zip"; echo "Could not fetch Bezzle-$V.zip: no delta from $V" >&2; }
done
ZIP="$DIST/Bezzle-$VERSION.zip"
# Zipped only now: a zip made earlier would hold the app without its ticket. ditto keeps the signatures.
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packed $(du -h "$ZIP" | cut -f1)"

echo "Signing the update and writing the feed…"
# generate_appcast keeps one cache for everyone; two at once spoil each other's deltas.
! pgrep -x generate_appcast >/dev/null || fail "Another generate_appcast is running (a Gerty release?): run again once it is done"
"$SPARKLE_DIR/bin/generate_appcast" "${KEY_ARGS[@]+"${KEY_ARGS[@]}"}" --maximum-versions "$((DELTAS_FROM + 1))" \
  --download-url-prefix "https://github.com/$SITE_REPO/releases/download/v$VERSION/" --link "$SITE/" "$DIST"
# The public feed: this version alone, with its deltas and its notes in every language.
python3 "$SRC/Scripts/release/notes.py" feed "$DIST/appcast.xml" "$WORK/appcast.xml" "$VERSION"
DELTAS="$(grep -oE 'url="[^"]+\.delta"' "$WORK/appcast.xml" | sed -E 's#.*/([^/"]+)"$#\1#' || true)"
ASSETS=("$ZIP")
for D in $DELTAS; do
  [ -f "$DIST/$D" ] || fail "The feed names $D, which generate_appcast did not write"
  ASSETS+=("$DIST/$D")
done
echo "Deltas from $(echo "$DELTAS" | grep -c . || true) earlier versions"

echo "Publishing the GitHub release…"
python3 "$SRC/Scripts/release/notes.py" github "$VERSION" > "$WORK/notes.md"
gh release create "v$VERSION" -R "$SITE_REPO" --title "Bezzle $VERSION" --notes-file "$WORK/notes.md" "${ASSETS[@]}"
DOWNLOAD="https://github.com/$SITE_REPO/releases/download/v$VERSION/Bezzle-$VERSION.zip"
# One byte of it, through GitHub's redirect; the total length comes with it.
LENGTH="$(curl -sSL -r 0-0 -D - -o /dev/null "$DOWNLOAD" | tr -d '\r' | sed -nE 's#^[Cc]ontent-[Rr]ange: bytes 0-0/([0-9]+)$#\1#p' | tail -1)"
[ "$LENGTH" = "$(stat -f %z "$ZIP")" ] || fail "$DOWNLOAD does not answer with the zip (length ${LENGTH:-none})"

# Only now the feed: nobody is offered an update whose files are not there yet.
echo "Publishing the feed and the notes on the website…"
gh repo clone "$SITE_REPO" "$WORK/site" -- --depth 1 -q
mkdir -p "$WORK/site/public/updates" "$WORK/site/src/releases"
cp "$WORK/appcast.xml" "$WORK/site/public/updates/appcast.xml"
cp "$SRC/RELEASE_NOTES.md" "$WORK/site/src/releases/RELEASE_NOTES.md"
# The site must build with them, as its Deploy workflow will, before they go up.
python3 "$WORK/site/src/build.py" >/dev/null || fail "The website does not build with the new feed and notes: nothing was pushed to it"
git -C "$WORK/site" add public/updates/appcast.xml src/releases/RELEASE_NOTES.md
git -C "$WORK/site" commit -q -m "Bezzle $VERSION" -m "The update feed and the release notes, from the app's Scripts/release.sh."
# gh's sign-in, for this push alone.
git -C "$WORK/site" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q origin HEAD:main
echo "Waiting for GitHub Pages…"
LIVE=""
for _ in $(seq 1 60); do
  if curl -fsS "$FEED_URL?check=$(date +%s)" 2>/dev/null | grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"; then LIVE=1; break; fi
  sleep 10
done
[ -n "$LIVE" ] || fail "After 10 minutes $FEED_URL still does not offer $VERSION: see the Deploy workflow at https://github.com/$SITE_REPO/actions. Once it does, tag the commit: git tag v$VERSION $COMMIT && git push origin refs/tags/v$VERSION"
curl -fsS "$SITE/download.html?check=$(date +%s)" | grep -qF "Bezzle-$VERSION.zip" || echo "The download page does not show $VERSION yet: check $SITE/download.html" >&2

# The tag comes last, as the mark that this version is out.
git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || git -C "$ROOT" tag "v$VERSION" "$COMMIT"
git -C "$ROOT" push -q origin "refs/tags/v$VERSION"
rm -f "$DIST"/*.delta
echo "Bezzle $VERSION is live: $SITE/download.html"
echo "Tagged v$VERSION. Pull ~/Sites/bezzle-web before changing the site."
