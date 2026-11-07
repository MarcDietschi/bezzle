// Tests designs shared by link in the browser (site/share.mjs with the core) against the relay
// itself, running on this Mac (`cd Relay && npx wrangler dev --port 8790`):
//  1. one copy shares a sample design; another opens it from the link alone, the same design;
//  2. each edits, and each takes in the other's edit, through the relay's sealed records;
//  3. many edits fold into wholes, and a copy that comes later opens everything;
//  4. pictures go up sealed under names the link's keys make, and come down whole;
//  5. nothing the relay keeps can be read without the link;
//  6. with --mac <file>, a design a Mac shared (CloudShareTests.forTheBrowser) opens here as the
//     Mac's own design to the byte, and an edit made here goes back for the Mac to check.
//
//   node tools/link.mjs [--relay http://127.0.0.1:8790] [--wasm <core>] [--mac <file>]

import { readFile, writeFile, readdir } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
import { createBezzle } from '../site/bezzle.mjs'
import { ShareKeys, SharedRoom, Relay, sha256hex, b64url, toB64, part } from '../site/share.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const relay = new Relay(arg('relay', 'http://127.0.0.1:8790'))
const wasmPath = arg('wasm', path.join(here, '..', '.build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm'))
const macFile = arg('mac')
const designs = path.join(here, '..', '..', 'AppStore', 'screenshots-src', 'designs')

const require = createRequire(import.meta.url)
const CK = await require('canvaskit-wasm/bin/canvaskit.js')({ locateFile: (f) => require.resolve(`canvaskit-wasm/bin/${f}`) })
const fontsDir = path.join(here, '..', 'site', 'fonts')
const manifest = JSON.parse(await readFile(path.join(fontsDir, 'manifest.json'), 'utf8'))
const fonts = {
  families: manifest.families,
  faces: await Promise.all(manifest.faces.map(async (f) => ({ ...f, data: await readFile(path.join(fontsDir, f.file)) }))),
  system: { ...manifest.system, data: await readFile(path.join(fontsDir, manifest.system.file)) },
}
const wasm = await readFile(wasmPath)
const core = () => createBezzle({ CanvasKit: CK, wasm, fonts, options: { trak: true } })

let failed = 0
const check = (ok, what) => { console.log(`${ok ? '  ok ' : '  FAIL'} ${what}`); if (!ok) failed++ }
const alike = (x, y) => {
  if (typeof x === 'number' && typeof y === 'number') return Math.abs(x - y) <= 1e-9 * Math.max(1, Math.abs(x))
  if (typeof x !== typeof y || (x === null) !== (y === null)) return false
  if (typeof x !== 'object' || x === null) return x === y
  if (Array.isArray(x) !== Array.isArray(y)) return false
  for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) if (!alike(x[k], y[k])) return false
  return true
}
const fromB64 = (s) => Uint8Array.from(Buffer.from(s, 'base64'))
const me = (replica, name) => ({ replica, writer: b64url(crypto.getRandomValues(new Uint8Array(32))), name })

// Opens a room as the page does: every part, into a core of its own.
async function join(keys, who) {
  const room = new SharedRoom({ keys, relay, me: me(who, who) })
  const bz = await core()
  const { parts, meta } = await room.load()
  const opened = bz.openShared(parts.map(toB64), who)
  return { room, bz, opened, meta }
}

async function catchUp(copy) {
  for (let i = 0; i < 4; i++) {
    const { parts, again } = await copy.room.poll()
    if (parts.length) copy.bz.receive(parts.map(toB64))
    if (!again) break
  }
}

async function edit(copy) {
  copy.bz.testEdit()
  const change = copy.bz.changes()
  if (!change.data) return false
  await copy.room.send(fromB64(change.data), change.upTo, () => fromB64(copy.bz.whole().data))
  return true
}

// MARK: 1 to 5, a browser sharing with browsers

const name = (await readdir(designs)).filter((n) => n.endsWith('.bezzle')).sort()[0]
const pkg = path.join(designs, name)
const pictures = new Map()
try { for (const f of await readdir(path.join(pkg, 'images'))) pictures.set(f, await readFile(path.join(pkg, 'images', f))) } catch {}
console.log(`${name}, ${pictures.size} pictures, relay ${relay.base}`)

const secret = crypto.getRandomValues(new Uint8Array(32))
const keys = await ShareKeys.fromSecret(secret)
const owner = b64url(crypto.getRandomValues(new Uint8Array(32)))
await relay.create(keys.room, { read: await sha256hex(keys.readToken), write: await sha256hex(keys.writeToken), owner: await sha256hex(owner) })

// The one sharing it: its whole design first, then its pictures, as the Mac does.
const anna = { room: new SharedRoom({ keys, relay, me: me('anna', 'Anna') }), bz: await core() }
anna.bz.open(await readFile(path.join(pkg, 'document.json')), pictures)
const original = anna.bz.document()
anna.bz.openShared([anna.bz.snapshot().data], 'anna', pictures)
const whole = anna.bz.whole()
await anna.room.put(`w.anna.${String(whole.upTo).padStart(15, '0')}`, fromB64(whole.data))
await anna.room.relay.put(keys.room, 'meta', await keys.seal(new TextEncoder().encode(JSON.stringify({ title: 'Poster', owner: 'Anna', made: Date.now() })), 'meta'),
  { write: keys.writeToken, owner })
await anna.room.introduce()
for (const [pic, data] of pictures) {
  const key = `p.${await keys.pictureName(pic)}`
  await relay.put(keys.room, key, await keys.seal(data, key), { write: keys.writeToken })
}

// 1. From the link alone.
const link = `https://bezzle.ch/open.html#2.${b64url(secret)}`
const ben = await join(await ShareKeys.fromLink(link), 'ben')
check(ShareKeys.secretIn(link) === b64url(secret) && ShareKeys.secretIn('https://x/open.html#2.short') === null, 'the secret comes out of the link, and only from a whole one')
check(ben.meta?.title === 'Poster' && ben.meta?.owner === 'Anna', 'the design’s name and owner come with it')
check(alike(ben.bz.document().nodes, original.nodes), `the design opens from the link, the same (${ben.opened.layers} layers)`)
check(ben.room.people.get('anna')?.name === 'Anna', 'who shared it is known by name')

// 2. Each edits; each takes in the other's.
check(await edit(ben), 'an edit in one copy goes out as a record of its own')
await catchUp(anna)
check(alike(anna.bz.document().nodes, ben.bz.document().nodes), 'the other copy takes it in, the same')
anna.bz.testEdit()
const fromAnna = anna.bz.changes()
await anna.room.send(fromB64(fromAnna.data), fromAnna.upTo, () => fromB64(anna.bz.whole().data))
await catchUp(ben)
check(alike(anna.bz.document().nodes, ben.bz.document().nodes), 'and the other way')

// 3. Many edits fold; a copy that comes later has everything.
// Nothing goes before a copy's second whole, so that there are always two: 60 edits make two.
for (let i = 0; i < 60; i++) { await edit(ben); if (i % 20 === 19) await catchUp(anna) }
await catchUp(anna)
const bens = [...ben.room.known.keys()].map(part).filter((p) => p?.replica === 'ben')
const listed = (await relay.list(keys.room, 0, keys.readToken)).records.map((r) => part(r.key)).filter((p) => p?.replica === 'ben')
check(listed.filter((p) => p.kind === 'w').length === 2 && listed.length < 61 && listed.length === bens.length,
  `ben’s records fold into two wholes (${listed.length} left on the relay of 63 written)`)
const carl = await join(keys, 'carl')
check(alike(carl.bz.document().nodes, ben.bz.document().nodes) && alike(anna.bz.document().nodes, ben.bz.document().nodes), 'a copy that comes later opens everything, as everyone has it')

// 4. Pictures.
if (pictures.size) {
  const [pic, data] = [...pictures][0]
  const down = await carl.room.picture(pic)
  check(down && Buffer.compare(Buffer.from(down), data) === 0, `a picture comes down whole (${Math.round(data.length / 1024)} KB)`)
  const listing = await relay.list(keys.room, 0, keys.readToken)
  check(!listing.records.some((r) => r.key.includes(pic.split('.')[0])), 'pictures go by names the link’s keys make, never their own')
}

// 5. Nothing without the link.
const stranger = await ShareKeys.fromSecret(crypto.getRandomValues(new Uint8Array(32)))
const someRecord = await relay.get(keys.room, [...ben.room.known.keys()].find((k) => k.startsWith('w.')), keys.readToken)
check(someRecord && (await stranger.open(someRecord, 'x')) === null, 'a record opens for no other key')
let refused = false
try { await relay.list(keys.room, 0, stranger.readToken) } catch (e) { refused = e.status === 403 }
check(refused, 'the relay lists nothing without the link’s token')

// The owner stops sharing: the others hear it.
let heard = false
const stop = carl.room.follow({ onNews: () => {}, onGone: () => { heard = true } })
await new Promise((ok) => setTimeout(ok, 500))
const del = await fetch(`${relay.base}/v2/${keys.room}`, { method: 'DELETE', headers: { Authorization: `Bearer ${keys.writeToken}`, 'X-Bezzle-Owner': owner } })
await new Promise((ok) => setTimeout(ok, 800))
stop()
let gone = false
try { await carl.room.poll() } catch (e) { gone = e.kind === 'gone' }
check(del.status === 204 && heard && gone, 'when the owner stops sharing, the others hear it at once, and the room is gone')

// MARK: 6, a Mac's design

if (macFile) {
  const shared = JSON.parse(await readFile(macFile, 'utf8'))
  const web = await join(await ShareKeys.fromLink(shared.link), 'webtest')
  const macDoc = shared.document, webDoc = new TextDecoder().decode(web.bz.documentBytes())
  let at = 0
  while (at < macDoc.length && macDoc[at] === webDoc[at]) at++
  check(macDoc === webDoc, macDoc === webDoc ? `a design the Mac shared opens here as the Mac’s, to the byte (${macDoc.length} bytes)`
    : `a design the Mac shared opens here: first difference at ${at}: mac …${macDoc.slice(at - 40, at + 40)}… web …${webDoc.slice(at - 40, at + 40)}…`)
  await web.room.introduce()
  check(await edit(web), 'an edit made here goes to the Mac')
  shared.browser = { text: 'Edited in a browser', document: new TextDecoder().decode(web.bz.documentBytes()) }
  await writeFile(macFile, JSON.stringify(shared))
}

console.log(failed ? `${failed} failed` : 'all passed')
process.exit(failed ? 1 : 0)
