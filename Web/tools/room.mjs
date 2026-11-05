// Shares a design to a relay as Bezzle on a Mac would, for trying site/shared.html: its whole
// design, its pictures, its name and owner. Prints the link, and with --edit every few seconds
// moves its first text, as someone working on it would, so the page shows changes coming in.
//
//   node tools/room.mjs <design.bezzle> [--relay http://127.0.0.1:8790] [--edit]

import { readFile, readdir } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
import { createBezzle } from '../site/bezzle.mjs'
import { ShareKeys, SharedRoom, Relay, sha256hex, b64url } from '../site/share.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const pkg = process.argv[2]
const relay = new Relay(arg('relay', 'http://127.0.0.1:8790'))

const require = createRequire(import.meta.url)
const CK = await require('canvaskit-wasm/bin/canvaskit.js')({ locateFile: (f) => require.resolve(`canvaskit-wasm/bin/${f}`) })
const fontsDir = path.join(here, '..', 'site', 'fonts')
const manifest = JSON.parse(await readFile(path.join(fontsDir, 'manifest.json'), 'utf8'))
const fonts = {
  families: manifest.families,
  faces: await Promise.all(manifest.faces.map(async (f) => ({ ...f, data: await readFile(path.join(fontsDir, f.file)) }))),
  system: { ...manifest.system, data: await readFile(path.join(fontsDir, manifest.system.file)) },
}
const bz = await createBezzle({ CanvasKit: CK, wasm: await readFile(path.join(here, '..', '.build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm')), fonts, options: { trak: true } })
const fromB64 = (s) => Uint8Array.from(Buffer.from(s, 'base64'))

const pictures = new Map()
try { for (const f of await readdir(path.join(pkg, 'images'))) pictures.set(f, await readFile(path.join(pkg, 'images', f))) } catch {}
const secret = crypto.getRandomValues(new Uint8Array(32))
const keys = await ShareKeys.fromSecret(secret)
const owner = b64url(crypto.getRandomValues(new Uint8Array(32)))
await relay.create(keys.room, { read: await sha256hex(keys.readToken), write: await sha256hex(keys.writeToken), owner: await sha256hex(owner) })
const room = new SharedRoom({ keys, relay, me: { replica: 'tryout', writer: b64url(crypto.getRandomValues(new Uint8Array(32))), name: 'Mia' } })

bz.open(await readFile(path.join(pkg, 'document.json')), pictures)
bz.openShared([bz.snapshot().data], 'tryout', pictures)
const whole = bz.whole()
await room.put(`w.tryout.${String(whole.upTo).padStart(15, '0')}`, fromB64(whole.data))
const title = path.basename(pkg, '.bezzle')
await relay.put(keys.room, 'meta', await keys.seal(new TextEncoder().encode(JSON.stringify({ title, owner: 'Mia', made: Date.now() })), 'meta'), { write: keys.writeToken, owner })
await room.introduce()
for (const [name, data] of pictures) {
  const key = `p.${await keys.pictureName(name)}`
  await relay.put(keys.room, key, await keys.seal(data, key), { write: keys.writeToken })
}
console.log(`#2.${b64url(secret)}`)
// For stopping it again: DELETE /v2/<room> with the write token and this.
console.log(`owner ${owner} room ${keys.room} write ${keys.writeToken}`)

if (process.argv.includes('--edit')) {
  setInterval(async () => {
    bz.testEdit()
    const change = bz.changes()
    if (change.data) await room.send(fromB64(change.data), change.upTo, () => fromB64(bz.whole().data))
    console.log('edited')
  }, 4000)
}
