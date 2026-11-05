// Bezzle's relay: one Durable Object per room, named after the room id. It never sees what is in
// a room: everything is sealed before it leaves a Mac or browser, with keys only the design's
// people have, and the room id is derived from those keys.
//
// v1, /v1/<room>: live messages between the Macs that have an iCloud-shared design open. iCloud
// keeps the design; this only makes it quick. Nothing is stored.
//
// v2, /v2/<room>: a design shared by link. The room holds its sealed, append-only records in the
// object's SQLite storage, behind read, write, owner and writer tokens (the room keeps only their
// SHA-256), and has live sockets at /v2/<room>/live. SHARING.md is the contract: the endpoints,
// the keys of records and who may write them, what each answer means. A synced-folder design's
// live room is a v2 room that is never created: no records, no tokens.
//
// Storage of a v2 room:
//   room     one row: token hashes, made, seq (the last write or delete), bytes, gone (ms once unshared)
//   records  key, seq, size, chunks, replica: the current records
//   chunks   seq, part, data: a record's bytes in rows of 1 MiB (a row holds at most 2 MB)
//   writers  replica, hash: the writer token a replica's records are bound to by its first write
//
// Live frames, all binary. To the relay:
//   0x10 payload                  to everyone else in the room
//   0x11 peer(u32) payload        to one of them
// From it:
//   0x01 you(u32) count(u16) peers(u32…)   on joining: who you are, and who is here
//   0x02 peer(u32)                         someone came
//   0x03 peer(u32)                         someone went
//   0x04 from(u32) payload                 a message
//   0x05 seq(u64)                          v2: records up to seq are there, fetch what is new
//   0x06                                   v2: the room was unshared; the socket closes
// The text "ping" is answered "pong" without waking the room.

const MAX_PEERS = 24;
const MAX_FRAME = 1 << 20;
const ROOM = /^\/v1\/([0-9a-f]{64})$/;
const SHARED = /^\/v2\/([0-9a-f]{64})(?:\/([^/]+))?$/;

const CHUNK = 1 << 20;
const MAX_RECORD = 32 * 1024 * 1024;
const MAX_ROOM = 2 * 1024 * 1024 * 1024;
const MAX_TOKEN = 512;

const CORS = { "access-control-allow-origin": "*" };
const PREFLIGHT = {
  ...CORS,
  "access-control-allow-methods": "GET, PUT, POST, DELETE, OPTIONS",
  "access-control-allow-headers": "Authorization, Content-Type, X-Bezzle-Writer, X-Bezzle-Owner",
  "access-control-max-age": "86400",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("Bezzle live relay\n", { headers: { "content-type": "text/plain" } });
    }
    if (url.pathname.startsWith("/v2/")) {
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: PREFLIGHT });
      const shared = SHARED.exec(url.pathname);
      if (!shared) return answer(404, { error: "not found" });
      if (shared[2] === "live" && request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return answer(426, { error: "expected a WebSocket" });
      }
      return env.ROOMS.get(env.ROOMS.idFromName(shared[1])).fetch(request);
    }
    const match = ROOM.exec(url.pathname);
    if (!match) return new Response("Not found\n", { status: 404 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket\n", { status: 426 });
    }
    const room = env.ROOMS.get(env.ROOMS.idFromName(match[1]));
    return room.fetch(request);
  },
};

export class Room {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.sql = ctx.storage.sql;
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const url = new URL(request.url);
    const shared = SHARED.exec(url.pathname);
    if (!shared) {
      // v1. A room created on v2 is only for those with its read token.
      const state = this.state();
      if (state?.gone) return new Response("The room was unshared\n", { status: 410 });
      if (state) return new Response("The room needs its read token\n", { status: 403 });
      return this.join();
    }
    const response = await this.respond(request, url, shared[2]);
    // A body not read to its end can cost the client its answer (the connection closes under
    // the upload), so whatever is left of it is read before answering: a refusal, a 409, a 413.
    if (request.body) await drain(request);
    return response;
  }

  async respond(request, url, key) {
    const method = request.method;
    try {
      if (key === "live") return await this.live(url);
      if (key === undefined) {
        if (method === "POST") return await this.create(request);
        if (method === "GET") return await this.list(request, url);
        if (method === "DELETE") return await this.unshare(request);
        return answer(405, { error: "method not allowed" }, { allow: "GET, POST, DELETE, OPTIONS" });
      }
      if (method === "GET") return await this.get(request, key);
      if (method === "PUT") return await this.put(request, key);
      if (method === "DELETE") return await this.remove(request, key);
      return answer(405, { error: "method not allowed" }, { allow: "GET, PUT, DELETE, OPTIONS" });
    } catch (error) {
      console.error(error);
      return answer(500, { error: "the relay failed" });
    }
  }

  // Live sockets: v1 rooms, and v2 rooms, with the read token when the room was created.

  async live(url) {
    const token = url.searchParams.get("read");
    const hashes = await tokenHashes(token);
    const state = this.state();
    if (state?.gone) return gone(state);
    if (state && !matches(hashes, state.read_hash)) return answer(403, { error: "wrong read token" });
    return this.join();
  }

  join() {
    const sockets = this.ctx.getWebSockets();
    if (sockets.length >= MAX_PEERS) return new Response("The room is full\n", { status: 429 });
    const taken = new Set(sockets.map(peerOf).filter((id) => id !== undefined));
    let id;
    do {
      id = crypto.getRandomValues(new Uint32Array(1))[0];
    } while (id === 0 || taken.has(id));

    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ id });

    const others = [...taken];
    const welcome = new Uint8Array(7 + others.length * 4);
    const view = new DataView(welcome.buffer);
    welcome[0] = 0x01;
    view.setUint32(1, id);
    view.setUint16(5, others.length);
    others.forEach((peer, i) => view.setUint32(7 + i * 4, peer));
    send(server, welcome);

    const joined = peerFrame(0x02, id);
    for (const s of sockets) send(s, joined);

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    if (typeof message === "string") return;
    const bytes = new Uint8Array(message);
    if (bytes.length < 1 || bytes.length > MAX_FRAME) return;
    const from = peerOf(ws);
    if (from === undefined) return;
    if (bytes[0] === 0x10) {
      const out = messageFrame(from, bytes.subarray(1));
      for (const s of this.ctx.getWebSockets()) if (s !== ws) send(s, out);
    } else if (bytes[0] === 0x11 && bytes.length >= 5) {
      const to = new DataView(bytes.buffer, bytes.byteOffset).getUint32(1);
      const out = messageFrame(from, bytes.subarray(5));
      for (const s of this.ctx.getWebSockets()) if (s !== ws && peerOf(s) === to) send(s, out);
    }
  }

  async webSocketClose(ws, code) {
    this.gone(ws);
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, "bye");
    } catch {}
  }

  async webSocketError(ws) {
    this.gone(ws);
  }

  gone(ws) {
    const id = peerOf(ws);
    if (id === undefined) return;
    const left = peerFrame(0x03, id);
    for (const s of this.ctx.getWebSockets()) if (s !== ws) send(s, left);
  }

  tell(frame) {
    for (const s of this.ctx.getWebSockets()) send(s, frame);
  }

  // v2 records. Each handler hashes its tokens and reads its body first (the awaits), then checks
  // and acts in one synchronous stretch, so nothing else in the room comes in between. A put also
  // checks before it reads the body, so a refusal or a 409 does not wait for the upload.

  async create(request) {
    const body = await readBody(request, 4096);
    const state = this.state();
    if (state?.gone) return gone(state);
    if (state) return answer(409, { error: "the room exists" });
    if (!body) return answer(413, { error: "too large" });
    let hashes;
    try {
      const json = JSON.parse(new TextDecoder().decode(body.parts[0] ?? new ArrayBuffer(0)));
      hashes = ["read", "write", "owner"].map((name) => (typeof json?.[name] === "string" ? json[name].toLowerCase() : ""));
    } catch {
      hashes = [];
    }
    if (hashes.length !== 3 || !hashes.every((hash) => /^[0-9a-f]{64}$/.test(hash))) {
      return answer(400, { error: "read, write and owner must each be SHA-256 hex" });
    }
    this.ctx.storage.transactionSync(() => {
      this.makeTables();
      this.sql.exec(
        "INSERT INTO room (one, read_hash, write_hash, owner_hash, made, seq, bytes, gone) VALUES (1, ?, ?, ?, ?, 0, 0, NULL)",
        ...hashes,
        Date.now(),
      );
    });
    return answer(201, { seq: 0 });
  }

  async list(request, url) {
    const hashes = await tokenHashes(bearer(request));
    const state = this.state();
    const refusal = refuse(state, hashes, "read");
    if (refusal) return refusal;
    const since = url.searchParams.get("since") ?? "0";
    if (!/^\d{1,15}$/.test(since)) return answer(400, { error: "since must be a seq" });
    const records = this.sql
      .exec("SELECT key, seq, size FROM records WHERE seq > ? ORDER BY seq", Number(since))
      .toArray();
    return answer(200, { seq: state.seq, bytes: state.bytes, records });
  }

  async get(request, key) {
    const hashes = await tokenHashes(bearer(request));
    const state = this.state();
    const refusal = refuse(state, hashes, "read");
    if (refusal) return refusal;
    if (!kindOf(key)) return answer(400, { error: "not a record key" });
    const record = this.record(key);
    if (!record) return answer(404, { error: "no such record" });
    return this.contents(record);
  }

  async put(request, key) {
    const kind = kindOf(key);
    const hashes = await tokenHashes(bearer(request));
    const owner = await tokenHashes(request.headers.get("x-bezzle-owner"));
    const writer = await writerHash(request);
    const check = () => {
      const state = this.state();
      const refusal = refuse(state, hashes, "write");
      if (refusal) return refusal;
      if (!kind) return answer(400, { error: "not a record key" });
      if (kind.by === "owner" && !matches(owner, state.owner_hash)) return answer(403, { error: "only the owner writes meta" });
      if (kind.by === "writer") {
        if (!writer) return answer(403, { error: "X-Bezzle-Writer is needed" });
        const bound = this.writerOf(kind.replica);
        if (bound && !same(bound, writer)) return answer(403, { error: "the replica belongs to another writer" });
      }
      const taken = kind.once && this.record(key);
      if (taken) return answer(409, { error: "taken", seq: taken.seq });
      return null;
    };

    const early = check();
    if (early) return early;
    const declared = request.headers.get("content-length");
    const body = declared !== null && Number(declared) > MAX_RECORD ? null : await readBody(request, MAX_RECORD);
    if (!body) return answer(413, { error: "a record holds at most 32 MB" });

    const done = this.ctx.storage.transactionSync(() => {
      const refusal = check();
      if (refusal) return { refusal };
      const state = this.state();
      const old = this.record(key);
      const bytes = state.bytes - (old?.size ?? 0) + body.size;
      if (bytes > MAX_ROOM) return { refusal: answer(413, { error: "a room holds at most 2 GB" }) };
      if (kind.by === "writer" && !this.writerOf(kind.replica)) {
        this.sql.exec("INSERT INTO writers (replica, hash) VALUES (?, ?)", kind.replica, writer);
      }
      const seq = state.seq + 1;
      body.parts.forEach((part, i) => this.sql.exec("INSERT INTO chunks (seq, part, data) VALUES (?, ?, ?)", seq, i, part));
      if (old) this.sql.exec("DELETE FROM chunks WHERE seq = ?", old.seq);
      this.sql.exec(
        `INSERT INTO records (key, seq, size, chunks, replica) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (key) DO UPDATE SET seq = excluded.seq, size = excluded.size, chunks = excluded.chunks, replica = excluded.replica`,
        key,
        seq,
        body.size,
        body.parts.length,
        kind.replica ?? null,
      );
      this.sql.exec("UPDATE room SET seq = ?, bytes = ? WHERE one = 1", seq, bytes);
      return { seq, status: old ? 200 : 201 };
    });
    if (done.refusal) return done.refusal;
    this.tell(seqFrame(done.seq));
    return answer(done.status, { seq: done.seq });
  }

  async remove(request, key) {
    const kind = kindOf(key);
    const hashes = await tokenHashes(bearer(request));
    const writer = await writerHash(request);
    const state = this.state();
    const refusal = refuse(state, hashes, "write");
    if (refusal) return refusal;
    if (!kind) return answer(400, { error: "not a record key" });
    if (!kind.foldable) return answer(403, { error: "only c. and w. records are deleted" });
    if (!writer) return answer(403, { error: "X-Bezzle-Writer is needed" });
    const bound = this.writerOf(kind.replica);
    if (bound && !same(bound, writer)) return answer(403, { error: "the replica belongs to another writer" });
    const old = this.record(key);
    if (!old) return answer(204);
    const seq = state.seq + 1;
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM chunks WHERE seq = ?", old.seq);
      this.sql.exec("DELETE FROM records WHERE key = ?", key);
      this.sql.exec("UPDATE room SET seq = ?, bytes = ? WHERE one = 1", seq, state.bytes - old.size);
    });
    this.tell(seqFrame(seq));
    return answer(204);
  }

  async unshare(request) {
    const hashes = await tokenHashes(bearer(request));
    const owner = await tokenHashes(request.headers.get("x-bezzle-owner"));
    const state = this.state();
    const refusal = refuse(state, hashes, "write");
    if (refusal) return refusal;
    if (!matches(owner, state.owner_hash)) return answer(403, { error: "only the owner unshares" });
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM chunks");
      this.sql.exec("DELETE FROM records");
      this.sql.exec("DELETE FROM writers");
      this.sql.exec(
        "UPDATE room SET gone = ?, bytes = 0, read_hash = '', write_hash = '', owner_hash = '' WHERE one = 1",
        Date.now(),
      );
    });
    const frame = Uint8Array.of(0x06);
    for (const s of this.ctx.getWebSockets()) {
      send(s, frame);
      try {
        s.close(1000, "unshared");
      } catch {}
    }
    return answer(204);
  }

  /** A record's sealed bytes: one row as it is, more streamed a row at a time. */
  contents(record) {
    const headers = { ...CORS, "content-type": "application/octet-stream", "cache-control": "no-store" };
    if (record.chunks <= 1) {
      const row = this.sql.exec("SELECT data FROM chunks WHERE seq = ? AND part = 0", record.seq).toArray()[0];
      return new Response(row?.data ?? new ArrayBuffer(0), { headers });
    }
    const sql = this.sql;
    let part = 0;
    const stream = new ReadableStream({
      pull(controller) {
        // Rows are under the seq of the write, so a record replaced or deleted meanwhile ends
        // the stream short rather than mixing two writes.
        const row = sql.exec("SELECT data FROM chunks WHERE seq = ? AND part = ?", record.seq, part).toArray()[0];
        if (!row) return controller.error(new Error("the record went while it was read"));
        controller.enqueue(new Uint8Array(row.data));
        if (++part === record.chunks) controller.close();
      },
    });
    return new Response(stream.pipeThrough(new FixedLengthStream(record.size)), { headers });
  }

  /** The room's row, or null for a room never created. It makes no tables: a v1 or live-only
   *  room keeps no storage at all. */
  state() {
    if (!this.tables) {
      const found = this.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'room'").toArray();
      if (found.length === 0) return null;
      this.tables = true;
    }
    return this.sql.exec("SELECT * FROM room WHERE one = 1").toArray()[0] ?? null;
  }

  makeTables() {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS room (
      one INTEGER PRIMARY KEY CHECK (one = 1),
      read_hash TEXT NOT NULL, write_hash TEXT NOT NULL, owner_hash TEXT NOT NULL,
      made INTEGER NOT NULL, seq INTEGER NOT NULL, bytes INTEGER NOT NULL, gone INTEGER)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS records (
      key TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE, size INTEGER NOT NULL,
      chunks INTEGER NOT NULL, replica TEXT)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS chunks (
      seq INTEGER NOT NULL, part INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY (seq, part))`);
    this.sql.exec("CREATE TABLE IF NOT EXISTS writers (replica TEXT PRIMARY KEY, hash TEXT NOT NULL)");
    this.tables = true;
  }

  record(key) {
    return this.sql.exec("SELECT key, seq, size, chunks, replica FROM records WHERE key = ?", key).toArray()[0] ?? null;
  }

  writerOf(replica) {
    return this.sql.exec("SELECT hash FROM writers WHERE replica = ?", replica).toArray()[0]?.hash ?? null;
  }
}

/** What a record key is, from SHARING.md's table: who writes it, and whether only once. Null for
 *  anything else. */
function kindOf(key) {
  let match;
  if (key === "meta") return { by: "owner", once: false };
  if ((match = /^m\.([a-z0-9]{1,32})$/.exec(key))) return { by: "writer", once: false, replica: match[1] };
  if ((match = /^[cw]\.([a-z0-9]{1,32})\.[0-9]{15}$/.exec(key))) return { by: "writer", once: true, replica: match[1], foldable: true };
  if (/^p\.[0-9a-f]{64}$/.test(key)) return { by: "anyone", once: true };
  const uuid = /^[vd]\.(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})$/;
  if (uuid.test(key)) return { by: "anyone", once: key[0] === "d" };
  return null;
}

/** 404 for a room never created, 410 once unshared, 403 without the right token. */
function refuse(state, hashes, token) {
  if (!state) return answer(404, { error: "no such room" });
  if (state.gone) return gone(state);
  if (!matches(hashes, state[`${token}_hash`])) return answer(403, { error: `wrong ${token} token` });
  return null;
}

function gone(state) {
  return answer(410, { gone: state.gone });
}

function answer(status, body, headers = {}) {
  const json = body === undefined ? null : JSON.stringify(body);
  return new Response(json, {
    status,
    headers: { ...CORS, "cache-control": "no-store", ...(json ? { "content-type": "application/json" } : {}), ...headers },
  });
}

function bearer(request) {
  return /^Bearer\s+(\S+)$/i.exec(request.headers.get("authorization") ?? "")?.[1] ?? null;
}

const encoder = new TextEncoder();

async function sha256(bytes) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** The hashes a token may be stored as: SHA-256 of its text as sent, and of the 32 bytes that
 *  text is in base64url. */
async function tokenHashes(token) {
  if (!token || token.length > MAX_TOKEN) return [];
  const hashes = [await sha256(encoder.encode(token))];
  const raw = fromBase64url(token);
  if (raw) hashes.push(await sha256(raw));
  return hashes;
}

/** The writer token is only ever hashed here, as its text. */
async function writerHash(request) {
  const token = request.headers.get("x-bezzle-writer");
  if (!token || token.length > MAX_TOKEN) return null;
  return sha256(encoder.encode(token));
}

function fromBase64url(text) {
  if (!/^[A-Za-z0-9_-]+$/.test(text)) return null;
  try {
    const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4));
    return Uint8Array.from(binary, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

function matches(hashes, stored) {
  let ok = false;
  for (const hash of hashes) ok = same(hash, stored) || ok;
  return ok;
}

/** Equal hex, in time that does not depend on where they differ. */
function same(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length === 0 || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** A body of at most `limit` bytes, in parts of CHUNK bytes; null when it is larger. */
async function readBody(request, limit) {
  const declared = request.headers.get("content-length");
  if (declared !== null && /^\d+$/.test(declared) && Number(declared) <= Math.min(CHUNK, limit)) {
    const buffer = await request.arrayBuffer();
    if (buffer.byteLength > limit) return null;
    return { size: buffer.byteLength, parts: buffer.byteLength ? [buffer] : [] };
  }
  const parts = [];
  let size = 0;
  let part = null;
  let fill = 0;
  if (request.body) {
    const reader = request.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
      size += bytes.byteLength;
      if (size > limit) {
        reader.releaseLock();
        return null;
      }
      for (let at = 0; at < bytes.byteLength; ) {
        if (!part) {
          part = new Uint8Array(CHUNK);
          fill = 0;
        }
        const n = Math.min(CHUNK - fill, bytes.byteLength - at);
        part.set(bytes.subarray(at, at + n), fill);
        fill += n;
        at += n;
        if (fill === CHUNK) {
          parts.push(part.buffer);
          part = null;
        }
      }
    }
  }
  if (part) parts.push(part.buffer.slice(0, fill));
  return { size, parts };
}

/** Reads what is left of a request's body, and lets it go. */
async function drain(request) {
  try {
    const reader = request.body?.getReader();
    if (reader) while (!(await reader.read()).done);
  } catch {}
}

function peerOf(ws) {
  try {
    return ws.deserializeAttachment()?.id;
  } catch {
    return undefined;
  }
}

function peerFrame(kind, id) {
  const frame = new Uint8Array(5);
  frame[0] = kind;
  new DataView(frame.buffer).setUint32(1, id);
  return frame;
}

function seqFrame(seq) {
  const frame = new Uint8Array(9);
  frame[0] = 0x05;
  new DataView(frame.buffer).setBigUint64(1, BigInt(seq));
  return frame;
}

function messageFrame(from, payload) {
  const frame = new Uint8Array(5 + payload.length);
  frame[0] = 0x04;
  new DataView(frame.buffer).setUint32(1, from);
  frame.set(payload, 5);
  return frame;
}

function send(ws, frame) {
  try {
    ws.send(frame);
  } catch {}
}
