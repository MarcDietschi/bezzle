# The relay

A Cloudflare Worker with a SQLite Durable Object per room (`src/worker.js`, `wrangler.toml`): it keeps
shared designs' sealed records and carries live co-working (pointers, selections, edits as they
happen). It reads nothing it holds: everything is sealed on the Mac, the PC or in the browser before
it is sent. `SHARING.md` is the protocol: the link, the keys, the records, the endpoints, the frames.

It runs at https://bezzle-live.bezzle-live.workers.dev, on Erik's Cloudflare account (wrangler is
signed in on this Mac). The Mac app reads that address from Info.plist (`BezzleLiveRelay`), Windows
from `Windows/Sources/BezzleCore/Host/Linking.swift`, the browser viewer from `Web/site/share.mjs`.
Version 1 (the iCloud era's live rooms) stays in the worker for copies older than 1.4.

## Running and testing

```sh
cd Relay
npm install
npm run dev                  # the relay on ws://127.0.0.1:8787
npm test                     # in another shell: the live rooms (relay-test) and sharing storage (sharing-test)
RELAY=https://bezzle-live.bezzle-live.workers.dev npm test   # the same against the deployed relay
```

The deployed test leaves only an unshared room's tombstone behind.

- **The Mac app against a local relay:** a Debug copy takes `BEZZLE_LIVE_RELAY=ws://127.0.0.1:8787`.
  Two copies on one Mac each need their own bundle id, `BEZZLE_REPLICA` and `BEZZLE_LIVE_NAME`;
  `BEZZLE_LIVE_DEMO=1|still|wink` gives one a pointer that moves by itself. Under tests the app never
  reaches the real relay.
- **Through the relay itself from the Mac's tests:** run `npx wrangler dev --port 8790` and set
  `TEST_RUNNER_BEZZLE_RELAY_TEST=http://127.0.0.1:8790` for `CloudShareTests` and `WindowsShareTests`.
- **The browser viewer:** `Web/tools/link.mjs` (browser to browser through `wrangler dev --port 8790`),
  and `--mac` with `CloudShareTests.forTheBrowser`.
- **Windows:** `BEZZLE_RELAY=<address>` points a test copy at another relay, and `off` keeps it off.

## Deploying

```sh
cd Relay && npx wrangler deploy
```

Then run the deployed test above. A change to the protocol is a change for every copy already
installed: keep what older copies send working (as version 1 is kept), and change `SHARING.md`,
the Mac (`Bezzle/Model/FolderShare.swift`, `Bezzle/Store/CloudShare.swift`), Windows and the browser
viewer (`Web/site/share.mjs`) together.
