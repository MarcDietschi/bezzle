// Bezzle's live relay: one Durable Object per shared design, passing sealed messages between the
// Macs that have it open. It never sees what is in them: each Mac seals everything with a key
// only the design's people have, and the room's name is a hash of that key. iCloud stays where
// the design is kept; this only makes it quick.
//
// Frames, all binary. To the relay:
//   0x10 payload                  to everyone else in the room
//   0x11 peer(u32) payload        to one of them
// From it:
//   0x01 you(u32) count(u16) peers(u32…)   on joining: who you are, and who is here
//   0x02 peer(u32)                         someone came
//   0x03 peer(u32)                         someone went
//   0x04 from(u32) payload                 a message
// The text "ping" is answered "pong" without waking the room.

const MAX_PEERS = 24;
const MAX_FRAME = 1 << 20;
const ROOM = /^\/v1\/([0-9a-f]{64})$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("Bezzle live relay\n", { headers: { "content-type": "text/plain" } });
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
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
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
