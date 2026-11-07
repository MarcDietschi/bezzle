# Bezzle

## Releases

Bezzle ships from its website alone, https://bezzle.ch/download.html, at the
version set in Xcode (`MARKETING_VERSION`); there is no App Store version (Erik, 2026-11-06).
`Scripts/release.sh` builds it with the Swift condition `BEZZLE_DIRECT`, and Sparkle keeps it up to
date (`Bezzle/App/Updates.swift`).

Sparkle is not in the Xcode project and its `SU…` keys are not in Info.plist: `release.sh` puts the
framework, the keys and the installer's sandbox entitlements into the released copy, and the app
loads Sparkle at run time only when it is there. So builds from Xcode, tests and test copies never
look for updates.

Whenever the version is raised, or Erik asks for a release:

1. **Write the notes.** Read what changed since the last release (`git describe --tags --abbrev=0`,
   then `git log` and `git diff <tag>..HEAD -- Bezzle`) and add the version at the top of
   `RELEASE_NOTES.md`, in English, German, French and Italian, in the same commit as the version
   change. Keep to the shape in the comment at the top of that file: `Scripts/release/notes.py`
   parses it, and the release refuses a version without its entry. The notes appear in Sparkle's
   update window in each Mac's language, on the GitHub release and on the site's What's New page.
2. **Run the tests**, then push. A release is made from the pushed commit, never the working tree.
3. **Run `Scripts/release.sh`** (about 15 minutes; `--dry-run` first puts a notarized zip on the
   Desktop and publishes nothing). It builds from `git archive` of the commit plus the git-ignored
   subject matte, exports with the Developer ID, adds Sparkle, signs, notarizes and staples. It then
   publishes the zip and delta updates as the GitHub release `v<version>` of mfrports/bezzle-web. It
   then commits the new feed and a copy of `RELEASE_NOTES.md` there, which rebuilds and deploys the
   site. Once the feed is live on bezzle.ch and on GitHub Pages it tags the commit `v<version>`, which
   marks the version as released.
4. **Check** https://bezzle.ch/download.html and `/updates/appcast.xml`.

How to write the notes: for the people who use Bezzle, not for developers. Say what they can do now
and why it matters, benefit first. Only what really shipped. Quiet and plain, no exclamation marks,
and no dashes as punctuation in any language. No internal names (Sparkle, CI, file names). Use the
app's own words for its controls, in each language as `Localizable.xcstrings` has them. German with
"du", written fresh rather than word for word; French and Italian with "tu", like the website. A
fix with nothing to show gets a title and a lede, no list.

### How the website copy is put together

- **Website**: https://bezzle.ch, a webspace at One.com (Erik, since 2026-11-07). Its own repository,
  mfrports/bezzle-web, locally `~/Sites/bezzle-web`, like gerty-web for Gerty. Its source (Vite,
  React and Tailwind: the pages, the words in four languages, the story's rebuilt window in
  `src/story/`, `public/img`) is edited there, and every push to its main deploys it to bezzle.ch by
  FTP (the repository's `FTP_*` secrets). GitHub Pages, mfrports.github.io/bezzle-web, where the
  site was before, then gets a redirect for every page (a link's # comes along) and the feed. Its
  README has the rest. This repository holds no part of the site.
- **Feed**: https://bezzle.ch/updates/appcast.xml, the file `public/updates/appcast.xml` in
  bezzle-web, is the `SUFeedURL` of the copies released after the move. The copies before it read
  https://mfrports.github.io/bezzle-web/updates/appcast.xml, which every deploy keeps the same file.
  Neither ever moves. It lists the newest version alone, with its deltas and its notes in every
  language. Only `release.sh` writes it.
- **Zips and deltas**: the releases of the public repository mfrports/bezzle-web (the app's own
  repository is private). `release.sh` keeps the last released zips in
  `~/Library/Caches/bezzle-release/dist`, fetching them from GitHub when missing, to make the deltas
  from. The subject matte makes a full zip about 225 MB, while a delta is small.
- **Site and release**: the site takes the version, the zip and its size from the feed, and What's New
  from its copy of the notes (`src/releases/RELEASE_NOTES.md`), so it shows only what can be
  downloaded. Edit the notes here, never that copy: the next release overwrites it.
- **Signing key**: Sparkle's EdDSA key is the one Gerty's releases use (login Keychain, account
  `ed25519`; also the `SPARKLE_PRIVATE_KEY` secret of mfrports/gerty). One key serves every app. Its
  public half is `SPARKLE_PUBLIC_KEY` in `release.sh`. Lose it, and no installed copy can be updated.
- **Links**: a shared design's link is `https://bezzle.ch/open.html#2.<secret>`; the app still takes
  the `mfrports.github.io` links made before the move (`Sharing.websites`).
- **Same app, same data**: both copies have the bundle id `com.erik.Bezzle` and the same sandbox
  container, so they open the same designs, share through the same relay (`Relay/SHARING.md`), and
  hand over to each other like two copies of one app (`HandOver`).
- **Withdrawing a version**: revert the release's commit in bezzle-web (the feed goes back to the
  version before), then `gh release delete v<version> -R mfrports/bezzle-web --cleanup-tag`. Copies that
  installed it keep it.
- **Testing the updater** without a release: build Release with
  `'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BEZZLE_DIRECT'`. Make two copies under a test
  bundle id (never `com.erik.Bezzle`, whose container holds Erik's designs), an older and a newer
  version, each with Sparkle inside and signed with Apple Development.
  Give them a throwaway CryptoKit Ed25519 key (`generate_appcast --ed-key-file`), a local
  `http://127.0.0.1` feed and `NSAllowsLocalNetworking`. Launch the older copy with `open -g -n`: it
  fetches the update within seconds. `NSRunningApplication.terminate()` quits it, and the newer
  version is in place a moment later. Done this way on 2026-11-04, with `SUAutomaticallyUpdate`,
  which releases no longer set: without it, the older copy shows Sparkle's window with the notes.
