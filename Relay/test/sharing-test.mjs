// Checks the sharing storage (v2, SHARING.md) of the relay running at RELAY (default
// http://127.0.0.1:8787; ws:// works too): creating a room, tokens, writing and reading records
// (one large enough to be stored in several rows), write-once and replaceable keys, writers bound
// to their replicas, meta for the owner alone, live sockets told of new records, and unsharing.
import { createHash, randomBytes, randomUUID } from "node:crypto";
import http from "node:http";

const relay = (process.env.RELAY ?? "http://127.0.0.1:8787").replace(/^ws/, "http").replace(/\/$/, "");
const live = relay.replace(/^http/, "ws");

const token = () => randomBytes(32).toString("base64url");
const sha = (data) => createHash("sha256").update(data).digest("hex");
const hex = (n) => randomBytes(n).toString("hex");
const upTo = (ms) => String(ms).padStart(15, "0");

function assert(ok, what) {
  if (!ok) {
    console.error("FAIL", what);
    process.exit(1);
  }
  console.log("ok  ", what);
}

async function call(method, path, { auth, writer, owner, body, headers = {} } = {}) {
  const h = { ...headers };
  if (auth) h.authorization = `Bearer ${auth}`;
  if (writer) h["x-bezzle-writer"] = writer;
  if (owner) h["x-bezzle-owner"] = owner;
  const response = await fetch(relay + path, { method, headers: h, body });
  const bytes = new Uint8Array(await response.arrayBuffer());
  let json;
  try {
    json = JSON.parse(new TextDecoder().decode(bytes));
  } catch {}
  return { status: response.status, headers: response.headers, bytes, json };
}

/** The HTTP status a WebSocket handshake gets: 101, or why not. */
function handshake(path) {
  return new Promise((resolve, reject) => {
    const url = new URL(relay + path);
    const request = http.request({
      host: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      headers: { Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": randomBytes(16).toString("base64") },
    });
    request.on("upgrade", (response, socket) => {
      socket.destroy();
      resolve(response.statusCode);
    });
    request.on("response", (response) => {
      response.resume();
      resolve(response.statusCode);
    });
    request.on("error", reject);
    request.end();
  });
}

function open(path, name) {
  const ws = new WebSocket(live + path);
  ws.binaryType = "arraybuffer";
  const inbox = [];
  const waiting = [];
  const closed = new Promise((resolve) => ws.addEventListener("close", (e) => resolve(e.code)));
  ws.onmessage = (e) => {
    const item = typeof e.data === "string" ? e.data : new Uint8Array(e.data);
    const w = waiting.shift();
    if (w) w(item);
    else inbox.push(item);
  };
  const next = () =>
    new Promise((resolve, reject) => {
      if (inbox.length) return resolve(inbox.shift());
      const timer = setTimeout(() => reject(new Error(`${name} heard nothing`)), 3000);
      waiting.push((item) => {
        clearTimeout(timer);
        resolve(item);
      });
    });
  const ready = new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error(`${name} could not connect`));
  });
  return { ws, next, ready, closed, inbox };
}

const seqOf = (frame) => Number(new DataView(frame.buffer, frame.byteOffset).getBigUint64(1));
const u32 = (b, at) => new DataView(b.buffer, b.byteOffset).getUint32(at);

const room = hex(32);
const read = token();
const write = token();
const owner = token();
const writerA = token();
const writerB = token();
const base = `/v2/${room}`;
const now = Date.now();

// Before the room is made.

const preflight = await fetch(`${relay}${base}/meta`, {
  method: "OPTIONS",
  headers: {
    origin: "https://bezzle.ch",
    "access-control-request-method": "PUT",
    "access-control-request-headers": "authorization,content-type,x-bezzle-owner,x-bezzle-writer",
  },
});
const allowed = (preflight.headers.get("access-control-allow-headers") ?? "").toLowerCase();
assert(
  preflight.status === 204 &&
    preflight.headers.get("access-control-allow-origin") === "*" &&
    ["authorization", "content-type", "x-bezzle-writer", "x-bezzle-owner"].every((h) => allowed.includes(h)) &&
    ["PUT", "POST", "DELETE"].every((m) => (preflight.headers.get("access-control-allow-methods") ?? "").includes(m)),
  "a browser's preflight is answered",
);

assert((await call("GET", `${base}?since=0`, { auth: read })).status === 404, "a room never made is not found");
const loose = open(`${base}/live`, "loose");
await loose.ready;
const looseWelcome = await loose.next();
assert(looseWelcome[0] === 0x01, "a room never made is live without tokens (synced folders)");
loose.ws.close();
await loose.closed;

// Making it.

assert((await call("POST", base, { body: JSON.stringify({ read: "x", write: sha(write), owner: sha(owner) }) })).status === 400, "a create without three hashes is refused");
const made = await call("POST", base, { body: JSON.stringify({ read: sha(read), write: sha(write), owner: sha(owner) }) });
assert(made.status === 201 && made.headers.get("access-control-allow-origin") === "*", "the room is made, 201, readable from a browser");
assert((await call("POST", base, { body: JSON.stringify({ read: sha(token()), write: sha(token()), owner: sha(token()) }) })).status === 409, "making it again is 409");

const empty = await call("GET", `${base}?since=0`, { auth: read });
assert(empty.status === 200 && empty.json.seq === 0 && empty.json.bytes === 0 && empty.json.records.length === 0, "a new room lists nothing at seq 0");

// Tokens.

assert((await call("GET", `${base}?since=0`)).status === 403, "listing without a token is 403");
assert((await call("GET", `${base}?since=0`, { auth: write })).status === 403, "listing with the write token is 403");
assert((await call("GET", `${base}?since=0`, { auth: token() })).status === 403, "listing with a wrong token is 403");
assert((await call("GET", `${base}?since=x`, { auth: read })).status === 400, "a since that is not a seq is 400");
assert((await handshake(`${base}/live`)) === 403, "live without the read token is 403");
assert((await handshake(`${base}/live?read=${token()}`)) === 403, "live with a wrong read token is 403");
assert((await handshake(`/v1/${room}`)) === 403, "a made room cannot be joined through v1");
assert((await call("GET", `${base}/live`, { auth: read })).status === 426, "live without a WebSocket is 426");

const a = open(`${base}/live?read=${read}`, "a");
await a.ready;
const welcomeA = await a.next();
assert(welcomeA[0] === 0x01 && new DataView(welcomeA.buffer).getUint16(5) === 0, "a is welcomed live with the read token");
const idA = u32(welcomeA, 1);
const b = open(`${base}/live?read=${read}`, "b");
await b.ready;
const welcomeB = await b.next();
const idB = u32(welcomeB, 1);
assert(welcomeB[0] === 0x01 && u32(welcomeB, 7) === idA, "b is welcomed with a there");
assert((await a.next())[0] === 0x02, "a hears b come");
b.ws.send(new Uint8Array([0x10, 7, 7]));
const message = await a.next();
assert(message[0] === 0x04 && u32(message, 1) === idB && message[5] === 7, "live messages pass as in v1");
b.ws.send("ping");
assert((await b.next()) === "pong", "ping is answered");

// meta: the owner's.

const sealed = (n) => randomBytes(n);
const metaKey = `${base}/meta`;
assert((await call("PUT", metaKey, { auth: write, body: sealed(80) })).status === 403, "meta without the owner token is 403");
assert((await call("PUT", metaKey, { auth: write, owner: token(), body: sealed(80) })).status === 403, "meta with a wrong owner token is 403");
assert((await call("PUT", metaKey, { auth: read, owner, body: sealed(80) })).status === 403, "a write with the read token is 403");
const meta = await call("PUT", metaKey, { auth: write, owner, body: sealed(80) });
assert(meta.status === 201 && meta.json.seq === 1, "the owner writes meta, 201, seq 1");
let frame = await a.next();
assert(frame.length === 9 && frame[0] === 0x05 && seqOf(frame) === 1, "a live socket hears 0x05 seq 1 after the put");
frame = await b.next();
assert(frame[0] === 0x05 && seqOf(frame) === 1, "and so does every other");
const meta2 = await call("PUT", metaKey, { auth: write, owner, body: sealed(90) });
assert(meta2.status === 200 && meta2.json.seq === 2, "the owner replaces meta, 200, seq 2");
assert(seqOf(await a.next()) === 2, "0x05 seq 2 after the replace");

// A replica's records: its writer's.

const memberA = sealed(120);
assert((await call("PUT", `${base}/m.alice`, { auth: write, body: memberA })).status === 403, "m. without a writer token is 403");
assert((await call("PUT", `${base}/m.alice`, { auth: write, writer: writerA, body: memberA })).status === 201, "m.alice is written, binding alice to her writer");
assert((await call("PUT", `${base}/m.alice`, { auth: write, writer: writerA, body: sealed(130) })).status === 200, "her writer replaces m.alice, 200");
assert((await call("PUT", `${base}/m.alice`, { auth: write, writer: writerB, body: sealed(130) })).status === 403, "another writer cannot write m.alice");
assert((await call("PUT", `${base}/m.bob`, { auth: write, writer: writerB, body: sealed(110) })).status === 201, "the other writer has a replica of its own");
const sinceHere = (await call("GET", `${base}?since=0`, { auth: read })).json.seq;

const big = sealed(3 * 1024 * 1024 + 12345);
const changeKey = `c.alice.${upTo(now)}`;
const change = await call("PUT", `${base}/${changeKey}`, { auth: write, writer: writerA, body: big, headers: { "content-type": "application/octet-stream" } });
assert(change.status === 201, "a 3 MB change is written, 201");
const back = await call("GET", `${base}/${changeKey}`, { auth: read });
assert(back.status === 200 && back.bytes.length === big.length && Buffer.compare(Buffer.from(back.bytes), big) === 0, "it reads back byte for byte (several rows)");
assert(back.headers.get("access-control-allow-origin") === "*", "a record is readable from a browser");
assert((await call("GET", `${base}/${changeKey}`, { auth: write })).status === 403, "reading a record with the write token is 403");
assert((await call("PUT", `${base}/${changeKey}`, { auth: write, writer: writerA, body: sealed(10) })).status === 409, "a c. record is written once: 409");
const again = await call("PUT", `${base}/${changeKey}`, { auth: write, writer: writerA, body: big });
assert(again.status === 409 && again.json.seq === change.json.seq, "a 409 says the seq it is at, large body or not");
assert((await call("PUT", `${base}/c.alice.${upTo(now + 1)}`, { auth: write, writer: writerB, body: sealed(10) })).status === 403, "another writer cannot write alice's changes");
assert((await call("DELETE", `${base}/${changeKey}`, { auth: write, writer: writerB })).status === 403, "another writer cannot delete them");
assert((await call("DELETE", `${base}/${changeKey}`, { auth: write })).status === 403, "nor can a delete without a writer");
const wholeKey = `w.alice.${upTo(now + 2)}`;
assert((await call("PUT", `${base}/${wholeKey}`, { auth: write, writer: writerA, body: sealed(5000) })).status === 201, "a w. record is written");
assert((await call("PUT", `${base}/${wholeKey}`, { auth: write, writer: writerA, body: sealed(5000) })).status === 409, "and only once");

// Anyone's records.

const pictureKey = `p.${hex(32)}`;
assert((await call("PUT", `${base}/${pictureKey}`, { auth: write, body: sealed(2000) })).status === 201, "a picture is written by anyone");
assert((await call("PUT", `${base}/${pictureKey}`, { auth: write, writer: writerB, body: sealed(2000) })).status === 409, "a picture is written once");
const versionKey = `v.${randomUUID().toUpperCase()}`;
assert((await call("PUT", `${base}/${versionKey}`, { auth: write, body: sealed(300) })).status === 201, "a version (UUID in capitals) is written");
assert((await call("PUT", `${base}/${versionKey}`, { auth: write, body: sealed(310) })).status === 200, "a version is replaceable");
const designKey = `d.${randomUUID()}`;
assert((await call("PUT", `${base}/${designKey}`, { auth: write, body: sealed(4000) })).status === 201, "a version's design (lowercase UUID) is written");
assert((await call("PUT", `${base}/${designKey}`, { auth: write, body: sealed(4000) })).status === 409, "and only once");

for (const key of ["metas", "m.", "m.Alice", "m." + "a".repeat(33), "c.alice", "c.alice.123", `c.alice.${upTo(now)}0`, "w.alice-1.000000000000001", `p.${hex(31)}`, `p.${hex(32).toUpperCase()}`, "v.not-a-uuid", `d.${randomUUID().replace(/^./, "A")}`, "x.foo"]) {
  const r = await call("PUT", `${base}/${key}`, { auth: write, writer: writerA, owner, body: sealed(10) });
  if (r.status !== 400) assert(false, `${key} is not a key (got ${r.status})`);
}
assert(true, "keys outside SHARING.md's table are 400");

assert((await call("DELETE", `${base}/meta`, { auth: write, owner })).status === 403, "meta cannot be deleted");
assert((await call("DELETE", `${base}/${pictureKey}`, { auth: write, writer: writerA })).status === 403, "pictures cannot be deleted");

// Listing.

const all = await call("GET", `${base}?since=0`, { auth: read });
const keys = all.json.records.map((r) => r.key);
const expected = ["meta", "m.alice", "m.bob", changeKey, wholeKey, pictureKey, versionKey, designKey];
assert(all.status === 200 && expected.every((k) => keys.includes(k)) && keys.length === expected.length, "listing since 0 gives every current record once");
const total = all.json.records.reduce((sum, r) => sum + r.size, 0);
assert(all.json.bytes === total && all.json.records.find((r) => r.key === changeKey).size === big.length, "with their sizes, and the room's bytes are their sum");
assert(all.json.records.every((r, i, list) => i === 0 || list[i - 1].seq < r.seq) && all.json.seq === all.json.records.at(-1).seq, "in seq order, and seq is the latest");
const later = await call("GET", `${base}?since=${sinceHere}`, { auth: read });
assert(
  later.json.records.length === 5 && later.json.records.every((r) => r.seq > sinceHere) && !later.json.records.some((r) => r.key.startsWith("m.") || r.key === "meta"),
  "listing since n gives only what came after n",
);

// What a heard of those writes, before what comes next.
await new Promise((resolve) => setTimeout(resolve, 300));
assert(a.inbox.length > 0 && a.inbox.every((f) => f[0] === 0x05), "every write was told live");
a.inbox.length = 0;

// Folding: a writer deletes its own.

const deleted = await call("DELETE", `${base}/${changeKey}`, { auth: write, writer: writerA });
assert(deleted.status === 204, "alice's writer deletes her change, 204");
frame = await a.next();
assert(frame[0] === 0x05 && seqOf(frame) === all.json.seq + 1, "the delete gets the next seq and is told live");
assert((await call("GET", `${base}/${changeKey}`, { auth: read })).status === 404, "the deleted record is gone");
const afterDelete = await call("GET", `${base}?since=0`, { auth: read });
assert(!afterDelete.json.records.some((r) => r.key === changeKey) && afterDelete.json.bytes === total - big.length && afterDelete.json.seq === all.json.seq + 1, "and no longer listed or counted");
assert((await call("GET", `${base}/c.alice.${upTo(1)}`, { auth: read })).status === 404, "a record never written is 404");

// Limits.

const tooBig = await call("PUT", `${base}/p.${hex(32)}`, { auth: write, body: Buffer.alloc(32 * 1024 * 1024 + 1) }).catch((e) => ({ status: e.message }));
assert(tooBig.status === 413, `a record over 32 MB is 413 (got ${tooBig.status})`);
let sent = 0;
const streamed = new ReadableStream({
  pull(controller) {
    if (sent > 33 * 1024 * 1024) return controller.close();
    controller.enqueue(new Uint8Array(1 << 20));
    sent += 1 << 20;
  },
});
const tooBigStreamed = await fetch(`${relay}${base}/p.${hex(32)}`, { method: "PUT", headers: { authorization: `Bearer ${write}` }, body: streamed, duplex: "half" })
  .then((r) => r.status)
  .catch((e) => e.message);
assert(tooBigStreamed === 413, `so is one sent without a length (got ${tooBigStreamed})`);
assert((await call("GET", `${base}?since=0`, { auth: read })).json.bytes === total - big.length, "and neither is kept");

// Hashes of the tokens' 32 bytes rather than their text are taken too.

const room2 = hex(32);
const [read2, write2, owner2] = [token(), token(), token()];
const raw = (t) => sha(Buffer.from(t, "base64url"));
assert((await call("POST", `/v2/${room2}`, { body: JSON.stringify({ read: raw(read2), write: raw(write2), owner: raw(owner2) }) })).status === 201, "a room made with hashes of the raw token bytes");
assert((await call("PUT", `/v2/${room2}/meta`, { auth: write2, owner: owner2, body: sealed(10) })).status === 201, "takes its write and owner tokens");
assert((await call("GET", `/v2/${room2}?since=0`, { auth: read2 })).json.records.length === 1, "and its read token");
assert((await call("DELETE", `/v2/${room2}`, { auth: write2, owner: owner2 })).status === 204, "and is unshared");

// Unsharing.

assert((await call("DELETE", base, { auth: write })).status === 403, "unsharing without the owner token is 403");
assert((await call("DELETE", base, { auth: read, owner })).status === 403, "unsharing without the write token is 403");
assert((await call("DELETE", base, { auth: write, owner })).status === 204, "the owner unshares, 204");
const bye = await a.next();
assert(bye.length === 1 && bye[0] === 0x06, "a live socket hears 0x06");
assert((await a.closed) === 1000 && (await b.closed) === 1000, "and every socket is closed");

const gone = await call("GET", `${base}?since=0`, { auth: read });
assert(gone.status === 410 && typeof gone.json.gone === "number" && gone.json.gone >= now, "listing is 410 {gone: ms}");
const goneAnswers = await Promise.all([
  call("GET", `${base}/${wholeKey}`, { auth: read }),
  call("PUT", `${base}/${pictureKey}`, { auth: write, body: sealed(10) }),
  call("PUT", `${base}/m.carol`, { auth: write, writer: token(), body: sealed(10) }),
  call("DELETE", `${base}/${wholeKey}`, { auth: write, writer: writerA }),
  call("DELETE", base, { auth: write, owner }),
  call("POST", base, { body: JSON.stringify({ read: sha(read), write: sha(write), owner: sha(owner) }) }),
  call("GET", `${base}?since=0`),
]);
assert(goneAnswers.every((r) => r.status === 410 && r.json?.gone === gone.json.gone), "every request after is 410, making the room again too");
assert((await handshake(`${base}/live?read=${read}`)) === 410, "live is 410");
assert((await handshake(`/v1/${room}`)) === 410, "and so is v1");

console.log("all good");
process.exit(0);
