// Checks the relay running at RELAY (default ws://127.0.0.1:8787): joining, passing messages to
// everyone and to one, leaving, and the ping answered without the room.
const base = process.env.RELAY ?? "ws://127.0.0.1:8787";
const room = "ab".repeat(32);

function open(name) {
  const ws = new WebSocket(`${base}/v1/${room}`);
  ws.binaryType = "arraybuffer";
  const inbox = [];
  const waiting = [];
  ws.onmessage = (e) => {
    const item = typeof e.data === "string" ? e.data : new Uint8Array(e.data);
    const w = waiting.shift();
    if (w) w(item); else inbox.push(item);
  };
  const next = () => new Promise((resolve, reject) => {
    if (inbox.length) return resolve(inbox.shift());
    const timer = setTimeout(() => reject(new Error(`${name} heard nothing`)), 3000);
    waiting.push((item) => { clearTimeout(timer); resolve(item); });
  });
  const ready = new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = () => reject(new Error(`${name} could not connect`)); });
  return { ws, next, ready, inbox };
}

const u32 = (b, at) => new DataView(b.buffer, b.byteOffset).getUint32(at);
function assert(ok, what) { if (!ok) { console.error("FAIL", what); process.exit(1); } console.log("ok  ", what); }

const a = open("a");
await a.ready;
const welcomeA = await a.next();
assert(welcomeA[0] === 0x01 && new DataView(welcomeA.buffer).getUint16(5) === 0, "a is welcomed alone");
const idA = u32(welcomeA, 1);

const b = open("b");
await b.ready;
const welcomeB = await b.next();
const idB = u32(welcomeB, 1);
assert(welcomeB[0] === 0x01 && new DataView(welcomeB.buffer).getUint16(5) === 1 && u32(welcomeB, 7) === idA, "b is welcomed with a there");
const joined = await a.next();
assert(joined[0] === 0x02 && u32(joined, 1) === idB, "a hears b come");

b.ws.send(new Uint8Array([0x10, 1, 2, 3]));
const m = await a.next();
assert(m[0] === 0x04 && u32(m, 1) === idB && m.length === 8 && m[5] === 1 && m[7] === 3, "a hears b's message, from b");

const direct = new Uint8Array(8);
direct[0] = 0x11;
new DataView(direct.buffer).setUint32(1, idB);
direct.set([9, 8, 7], 5);
a.ws.send(direct);
const d = await b.next();
assert(d[0] === 0x04 && u32(d, 1) === idA && d[5] === 9, "b hears what a sent to b alone");

a.ws.send("ping");
assert((await a.next()) === "pong", "ping is answered");

b.ws.close();
const left = await a.next();
assert(left[0] === 0x03 && u32(left, 1) === idB, "a hears b go");
a.ws.close();
console.log("all good");
process.exit(0);
