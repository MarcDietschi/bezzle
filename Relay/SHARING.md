# Sharing through the relay (v2)

A shared design lives on Cloudflare as a room: one Durable Object holding sealed, append-only
records, plus the live sockets of whoever has it open. The Mac that shared it keeps its own file
wherever it is; every copy (Macs and browsers) writes only records of its own and merges everyone's,
with `SharedDesign`'s merge (idempotent, order-free), so no edit is ever lost or written over.
Cloudflare holds only what it cannot read: everything is sealed before it leaves a Mac or browser.

Anyone with the link can work on the design. No accounts: a person is the name they give.

## The link

    https://mfrports.github.io/bezzle-web/open.html#2.<secret>
    bezzle://share/2.<secret>

`<secret>` is 32 random bytes, base64url without padding (43 characters). The fragment never
reaches a server. `2.` is the version.

## Keys

Every key is HKDF-SHA256 over the secret, salt `bezzle-share-2` (UTF-8), 32 bytes, with info:

| info    | use                                                                    |
|---------|------------------------------------------------------------------------|
| `room`  | the room id: lowercase hex, 64 characters                              |
| `read`  | read token: base64url, sent as `Authorization: Bearer <read>` on reads |
| `write` | write token: base64url, `Authorization: Bearer <write>` on writes      |
| `seal`  | AES-256-GCM master key                                                 |
| `names` | HMAC-SHA256 key that names pictures                                    |

The sharer also makes an **owner token** (32 random bytes, base64url) that never goes in the link,
for unsharing; and every copy makes a **writer token** of its own, sent as
`X-Bezzle-Writer: <token>` with every write, which binds its replica's records to it.

A synced-folder design's live room (`sharing/room.json`, `seed` = 64 hex) uses the same keys with
the seed's 32 bytes as the secret; it is never created, so it has no records and no tokens.

## Sealing

    sealed = 0x02 ‖ salt[16] ‖ nonce[12] ‖ AES-256-GCM(subkey, nonce, plaintext, aad) ‖ tag[16]
    subkey = HKDF-SHA256(ikm: seal key, salt: salt, info: "bezzle-seal-2", 32 bytes)

`salt` is random once per sender session (one connection, one app launch) and stays the same for
everything it seals; receivers cache subkeys by salt. `nonce` is random per message. With a subkey
per session no key comes near 2^32 seals.

`aad` is UTF-8: `<room>/<record key>` for a record, `<room>/live` for a live message.

Live messages keep their plaintext as now: one flag byte (0 plain, 1 LZFSE) and the `LiveMessage`
JSON.

## Records

Keys are ASCII. `<replica>` is `[a-z0-9]{1,32}`, `<upTo>` is milliseconds since 1970, 15 digits,
zero-padded, and strictly increasing per replica.

| key                    | plaintext                                                  | writes             |
|------------------------|------------------------------------------------------------|--------------------|
| `meta`                 | JSON `{"title","owner","made"}` (owner's name, ms)          | owner, replaceable |
| `m.<replica>`          | JSON `{"replica","name","app","since"}` (app `mac`/`web`)   | its writer, replaceable |
| `c.<replica>.<upTo>`   | changes: `SharedDesign` JSON, then LZFSE                    | its writer, once   |
| `w.<replica>.<upTo>`   | the whole design as that copy had it, same packing          | its writer, once   |
| `p.<hex64>`            | picture bytes; hex = HMAC-SHA256(names key, picture name)   | anyone, once       |
| `v.<UUID>`             | JSON `DesignVersion` of a named version (dates in ms)       | anyone, replaceable |
| `d.<UUID>`             | that version's design (`VersionFiles.pack`: JSON, LZFSE)    | anyone, once       |

A `c.` record may hold others' changes too (whatever that copy took in since its last record); it
is merged the same way.

**Reading.** Per replica: its newest `w.` that opens, and every `c.` after it. The `c.` up to that
whole are in it. A `w.` that will not open is passed over for the one before. Pictures are fetched
when a layer shows one that is not there yet.

**Folding.** A copy with 24 `c.` records since its last `w.` writes a new `w.` (everything it has),
then deletes its own `c.` and `w.` records from before its previous `w.`, which stays, so there are
always two wholes.

## Endpoints

Base: the relay, `https://bezzle-live.bezzle-live.workers.dev` (`BezzleLiveRelay` with `https`).

| request | tokens | answer |
|---------|--------|--------|
| `POST /v2/<room>` body `{"read","write","owner"}` = SHA-256 hex of each token's base64url text | none | 201; 409 exists; 410 unshared |
| `GET /v2/<room>?since=<seq>` | read | 200 `{"seq","bytes","records":[{"key","seq","size"}]}`: current records with seq > since; 404; 410 `{"gone":<ms>}` |
| `GET /v2/<room>/<key>` | read | the sealed bytes; 404 |
| `PUT /v2/<room>/<key>` body sealed | write, writer for `m.`/`c.`/`w.`, `X-Bezzle-Owner` for `meta` | 201 new; 200 replaced; 409 write-once taken (same as done); 403; 413 |
| `DELETE /v2/<room>/<key>` | write, writer (only `c.`/`w.` of that writer) | 204 |
| `DELETE /v2/<room>` | write, `X-Bezzle-Owner` | 204: everything goes, the room stays gone (410) for good |
| `GET /v2/<room>/live?read=<read token>` WebSocket | read (none for a room never created) | live frames |

Every write gets the next `seq`. Limits: 32 MiB a record, 2 GiB a room.

As built (`src/worker.js`, `test/sharing-test.mjs`): a v2 request is checked for 410 first, then
404 (a room never created, also for writes), then 403, then 400 for a bad key. A 409 for a taken
write-once key carries `{"error":"taken","seq":n}`; the Mac takes it as done. `DELETE` of a record
that is already gone answers 204 and takes no seq. `p.` keys are lowercase hex; the Mac writes
`v.`/`d.` UUIDs in uppercase (`uuidString`), and a key is stored as sent, as the seal covers it.
v1 refuses a room created on v2 (403) or unshared (410), so it can't be used to skip the read token.

## Live frames

As v1 (see `src/worker.js`), plus from the relay:

    0x05 seq(u64)    records up to seq are there: fetch what is new
    0x06             the room was unshared; the socket closes

## Unsharing

Only the owner can (`DELETE /v2/<room>`): its own copy becomes a design of its own again, and every
other copy keeps the design as it last was, read only, marked no longer shared (410, or `0x06`).
A new link is a new room: unshare, then share again.
