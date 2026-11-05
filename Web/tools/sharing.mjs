// Tests shared designs in the browser's core without iCloud, on the sample designs:
//  1. a design packed as its owner's snapshot opens as the same design, drawn the same;
//  2. Apple's LZFSE on this Mac and the browser's read each other's records;
//  3. an edit made in one browser goes out as a change record that another takes in;
//  4. with --truth, a snapshot the Mac packed makes, byte for byte, the design the Mac made of it
//     (WebTruthTests writes both into <truth>/shared).
//
// The model's own round trip leaves the last digits of some numbers as they come out (26.73 as
// 26.729999999999997), on the Mac as here, so 1 to 3 compare numbers to a billionth; 4 is exact.
//
//   node tools/sharing.mjs [--wasm <core>] [--truth <dir>]

import { readFile, writeFile, readdir, mkdtemp } from 'node:fs/promises'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { createBezzle } from '../site/bezzle.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const wasmPath = arg('wasm', path.join(here, '..', '.build/out/Products/Debug-webassembly-wasm32/BezzleCore.wasm'))
const designs = path.join(here, '..', '..', 'AppStore', 'screenshots-src', 'designs')
const truth = arg('truth')

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
const [a, b] = [await core(), await core()]
const work = await mkdtemp(path.join(tmpdir(), 'bezzle-sharing-'))

const pixels = (img) => img.readPixels(0, 0, { width: img.width(), height: img.height(), colorType: CK.ColorType.RGBA_8888, alphaType: CK.AlphaType.Unpremul, colorSpace: CK.ColorSpace.SRGB })
const samePixels = (x, y) => { const p = pixels(x), q = pixels(y); return p.length === q.length && p.every((v, i) => v === q[i]) }
const mac = (mode, data) => {
  const i = path.join(work, 'in'), o = path.join(work, 'out')
  return writeFile(i, data).then(() => { execFileSync('swift', [path.join(here, 'lzfse-mac.swift'), mode, i, o]); return readFile(o) })
}

// Alike, but for the last digits of numbers.
const alike = (x, y) => {
  if (typeof x === 'number' && typeof y === 'number') return Math.abs(x - y) <= 1e-9 * Math.max(1, Math.abs(x))
  if (typeof x !== typeof y || (x === null) !== (y === null)) return false
  if (typeof x !== 'object' || x === null) return x === y
  if (Array.isArray(x) !== Array.isArray(y)) return false
  const keys = new Set([...Object.keys(x), ...Object.keys(y)])
  for (const k of keys) if (!alike(x[k], y[k])) return false
  return true
}

let failed = 0
const check = (ok, what) => { console.log(`${ok ? '  ok ' : '  FAIL'} ${what}`); if (!ok) failed++ }

for (const name of (await readdir(designs)).filter((n) => n.endsWith('.bezzle')).sort()) {
  const pkg = path.join(designs, name)
  const pictures = new Map()
  try { for (const f of await readdir(path.join(pkg, 'images'))) pictures.set(f, await readFile(path.join(pkg, 'images', f))) } catch {}
  console.log(name)

  // 1. The design as it is, then as its snapshot.
  const opened = a.open(await readFile(path.join(pkg, 'document.json')), pictures)
  const plain = opened.boards.map((x) => a.render(x.index, 1).image)
  const original = a.document()
  const { data: snapshot } = a.snapshot()
  const shared = a.openShared([snapshot], 'web-a', pictures)
  check(shared.unread === 0 && shared.boards.length === opened.boards.length, `snapshot opens (${Math.round(Buffer.from(snapshot, 'base64').length / 1024)} KB packed, ${shared.layers} layers)`)
  check(alike(a.document().nodes, original.nodes), 'same layers as the design')
  check(shared.boards.every((x, k) => samePixels(a.render(x.index, 1).image, plain[k])), 'drawn the same, pixel for pixel')

  // 2. Apple's LZFSE: the Mac unpacks the browser's snapshot, and packs it again for the browser.
  const json = await mac('unpack', Buffer.from(snapshot, 'base64'))
  const repacked = await mac('pack', json)
  const fromMac = b.openShared([repacked.toString('base64')], 'web-b', pictures)
  check(fromMac.unread === 0 && alike(b.document().nodes, original.nodes), "Apple's LZFSE and the browser's read each other")

  // 3. An edit in browser a, as a change record, taken in by browser b.
  a.testEdit()
  const change = a.changes()
  check(!!change.data, `the edit goes out as a change record (${change.data ? Buffer.from(change.data, 'base64').length : 0} bytes packed)`)
  b.receive([change.data])
  check(alike(b.document().nodes, a.document().nodes), 'the other browser has it, the same')
  check(JSON.stringify(a.changes()) === '{}', 'nothing more to send')

  // 4. The Mac's own snapshot, opened here: the Mac's design to the byte.
  if (truth) {
    const base = path.join(truth, 'shared', name.replace(/\.bezzle$/, ''))
    const macDoc = (await readFile(`${base}.document.json`)).toString()
    b.openShared([(await readFile(`${base}.snapshot`)).toString('base64')], 'web-b', pictures)
    const webDoc = new TextDecoder().decode(b.documentBytes())
    let at = 0
    while (at < macDoc.length && macDoc[at] === webDoc[at]) at++
    check(macDoc === webDoc, macDoc === webDoc ? `the Mac's snapshot makes the Mac's design, to the byte (${macDoc.length} bytes)`
      : `the Mac's snapshot makes the Mac's design: first difference at ${at}: mac …${macDoc.slice(at - 30, at + 30)}… web …${webDoc.slice(at - 30, at + 30)}…`)
  }
}
console.log(failed ? `${failed} failed` : 'all passed')
process.exit(failed ? 1 : 0)
