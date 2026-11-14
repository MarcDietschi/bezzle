// Holds the core's reading of the icon library to the Mac's. IconTruthTests writes
// <truth>/icons/icons.json and the Mac's drawing of a sheet of icons; here the library
// (Bezzle/Model/Kits/Icons.deflate, raw DEFLATE) is unpacked as a page unpacks it, with the
// browser's own DecompressionStream, and handed to the core (bz.icons):
//
//  - the same sets, each with the same name, licence, box, styles and icons (a digest of every
//    icon's name, words and outlines);
//  - the same icons found for the same words, in the same order;
//  - the outlines of a set of outlines the set's own, those grown from lines in the same box;
//  - the sheet, made by the core of its own icons, drawn as the Mac drew its own.
//
// With --browser all of it in a headless Chromium (tools/headless.mjs), which also says how long
// the unpacking and the reading take there.
//
//   node tools/icons.mjs --truth <dir> [--browser] [--chrome <path>] [--wasm <core>] [--out <dir>]

import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
import { createBezzle } from '../site/bezzle.mjs'
import { launch } from './headless.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const web = path.join(here, '..')
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const flag = (name) => process.argv.includes(`--${name}`)
const truthDir = arg('truth')
const out = arg('out', path.join(web, 'out'))
const wasmPath = arg('wasm', path.join(web, '.build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm'))
const library = path.join(web, '..', 'Bezzle', 'Model', 'Kits', 'Icons.deflate')
if (!truthDir) { console.error('Give the Mac’s truth: --truth <dir> (IconTruthTests writes <dir>/icons/icons.json)'); process.exit(2) }
const truth = JSON.parse(await readFile(path.join(truthDir, 'icons', 'icons.json'), 'utf8'))
await mkdir(out, { recursive: true })

const require = createRequire(import.meta.url)
const CK = await require('canvaskit-wasm/bin/canvaskit.js')({ locateFile: (f) => require.resolve(`canvaskit-wasm/bin/${f}`) })
const fontsDir = path.join(web, 'site', 'fonts')

// The core: here in Node, or in a page of a headless Chromium answering the same questions.
const HARNESS = `<!doctype html><meta charset="utf-8"><title>Icons</title><body>
<script type="module">
import { createBezzle } from '/site/bezzle.mjs'
try {
  await new Promise((ok, fail) => { const s = document.createElement('script'); s.src = '/canvaskit/canvaskit.js'; s.onload = ok; s.onerror = fail; document.head.append(s) })
  const CK = await window.CanvasKitInit({ locateFile: (f) => '/canvaskit/' + f })
  const bytes = async (url) => new Uint8Array(await (await fetch(url)).arrayBuffer())
  const manifest = await (await fetch('/site/fonts/manifest.json')).json()
  const fonts = { families: manifest.families, faces: [], system: { ...manifest.system, data: await bytes('/site/fonts/' + manifest.system.file) } }
  const bz = await createBezzle({ CanvasKit: CK, wasm: await bytes('/core.wasm'), fonts, options: { trak: true } })
  window.harness = {
    async icons() {
      const t0 = performance.now()
      const packed = await bytes('/Icons.deflate')
      const t1 = performance.now()
      const sets = await bz.icons(packed)
      return { ...sets, packed: packed.length, fetchMs: t1 - t0, readMs: performance.now() - t1 }
    },
    test: (asked) => bz.testIcons(asked),
    render(index, scale) {
      const png = bz.render(index, scale).image.encodeToBytes()
      let s = ''
      for (let k = 0; k < png.length; k += 0x8000) s += String.fromCharCode.apply(null, png.subarray(k, k + 0x8000))
      return btoa(s)
    },
  }
  window.ready = true
} catch (e) { window.failed = String(e?.stack ?? e) }
</script>`

let core, browser = null
if (flag('browser')) {
  browser = await launch({ chrome: arg('chrome'), pages: { '/harness.html': HARNESS }, files: { '/core.wasm': wasmPath, '/Icons.deflate': library },
    roots: { '/site/': path.join(web, 'site'), '/canvaskit/': path.dirname(require.resolve('canvaskit-wasm/bin/canvaskit.js')) } })
  const page = await browser.open('/harness.html')
  core = {
    icons: () => page.call('icons'),
    test: (asked) => page.call('test', asked),
    render: async (index, scale) => CK.MakeImageFromEncoded(Buffer.from(await page.call('render', index, scale), 'base64')),
  }
} else {
  const manifest = JSON.parse(await readFile(path.join(fontsDir, 'manifest.json'), 'utf8'))
  const fonts = { families: manifest.families, faces: [], system: { ...manifest.system, data: await readFile(path.join(fontsDir, manifest.system.file)) } }
  const bz = await createBezzle({ CanvasKit: CK, wasm: await readFile(wasmPath), fonts, options: { trak: true } })
  core = {
    async icons() {
      const packed = await readFile(library)
      const t = performance.now()
      const sets = await bz.icons(packed)
      return { ...sets, packed: packed.length, readMs: performance.now() - t }
    },
    test: async (asked) => bz.testIcons(asked),
    render: async (index, scale) => bz.render(index, scale).image,
  }
}

let failed = 0, checked = 0
const check = (ok, what) => { checked++; console.log(`${ok ? '  ok ' : '  FAIL'} ${what}`); if (!ok) failed++ }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

try {
  // Before the library is handed over the core has no icons, and says so.
  const none = await core.test({ facts: true })
  const took = await core.icons()
  console.log(`${flag('browser') ? 'Headless Chromium' : 'Node'}: ${(took.packed / 1e6).toFixed(2)} MB packed${took.fetchMs !== undefined ? `, fetched in ${Math.round(took.fetchMs)} ms` : ''}, unpacked and read by the core in ${Math.round(took.readMs)} ms`)
  check(none.sets.length === 0 && took.sets.length === truth.sets.length, `no sets before the library is handed over, ${took.sets.length} after`)

  const facts = await core.test({ facts: true })
  for (const mac of truth.sets) {
    const own = facts.sets.find((s) => s.id === mac.id)
    check(!!own && same([own.name, own.licence, own.box, own.stroke, own.styles, own.icons], [mac.name, mac.licence, mac.box, mac.stroke, mac.styles, mac.icons]),
      `${mac.name}: ${mac.icons} icons in ${mac.styles.length} ${mac.styles.length === 1 ? 'style' : 'styles'} on a box of ${mac.box[2]}, ${mac.licence}`)
    check(own?.digest === mac.digest, `${mac.name}: every icon's name, words and outlines as the Mac has them (${mac.digest.slice(0, 12)}…)`)
  }

  const found = await core.test({ search: truth.searches.map(({ query, set, limit }) => ({ query, set, limit })) })
  truth.searches.forEach((mac, i) => {
    check(same(found.found[i], mac.found), `“${mac.query}”${mac.set ? ` in ${mac.set}` : ''}: ${mac.found.length} found, ${mac.found.slice(0, 3).map((n) => n.split('/')[1]).join(', ') || 'none'}${mac.found.length > 3 ? '…' : ''}`)
  })

  // Outlines: a set of outlines hands on its own words; a set of lines grows them, each stroker
  // in its own points, into the same box.
  const made = await core.test({ outlines: truth.outlines.map(({ set, name, style, weight }) => ({ set, name, style, weight })) })
  const own = truth.outlines.filter((o) => o.data !== undefined), grown = truth.outlines.filter((o) => o.data === undefined)
  check(own.every((mac) => { const w = made.outlines[truth.outlines.indexOf(mac)]; return w?.data === mac.data && same(w.box, mac.box) }), `${own.length} outlines of Phosphor's and Material's, in every style: the set's own, on its box`)
  let furthest = 0, worst = ''
  for (const mac of grown) {
    const w = made.outlines[truth.outlines.indexOf(mac)]
    // On Lucide's box of 24: how far a side of the grown outline's box is from the Mac's.
    const d = w ? Math.max(...[0, 1].flatMap((k) => [Math.abs(w.box[k] - mac.box[k]), Math.abs(w.box[k] + w.box[k + 2] - mac.box[k] - mac.box[k + 2])])) : Infinity
    if (d > furthest) { furthest = d; worst = `${mac.name} at ${mac.weight}` }
  }
  check(furthest < 0.02, `${grown.length} outlines grown from Lucide's lines, weights 0.25 to 6: their boxes within ${furthest.toExponential(1)} of the Mac's on a box of 24 (${worst})`)

  // The sheet: the core's own icons, drawn here, beside the Mac's drawing of its own.
  const sheet = await core.test({ sheet: truth.sheet })
  check(sheet.drawn === truth.sheet.icons.length && sheet.missing === 0, `a sheet of ${truth.sheet.icons.length} icons: every one found`)
  const web_ = await core.render(0, 2)
  const mac = CK.MakeImageFromEncoded(await readFile(path.join(truthDir, 'icons', 'Icons-0.png')))
  await writeFile(path.join(out, 'Icons-0.own.png'), web_.encodeToBytes())
  const pixels = (img) => img.readPixels(0, 0, { width: img.width(), height: img.height(), colorType: CK.ColorType.RGBA_8888, alphaType: CK.AlphaType.Unpremul, colorSpace: CK.ColorSpace.SRGB })
  if (mac.width() !== web_.width() || mac.height() !== web_.height()) {
    check(false, `the sheet's size: the Mac's ${mac.width()}×${mac.height()}, here ${web_.width()}×${web_.height()}`)
  } else {
    const a = pixels(mac), w = pixels(web_)
    const diff = new Uint8Array(a.length)
    let sum = 0, off = 0, most = 0
    for (let k = 0; k < a.length; k += 4) {
      const d = Math.max(Math.abs(a[k] - w[k]), Math.abs(a[k + 1] - w[k + 1]), Math.abs(a[k + 2] - w[k + 2]))
      sum += d
      most = Math.max(most, d)
      if (d > 24) off++
      const g = (a[k] + a[k + 1] + a[k + 2]) / 3 * 0.35 + 160
      diff.set(d > 24 ? [255, 40, 40, 255] : [g, g, g, 255], k)
    }
    const n = a.length / 4
    const di = CK.MakeImage({ width: mac.width(), height: mac.height(), alphaType: CK.AlphaType.Unpremul, colorType: CK.ColorType.RGBA_8888, colorSpace: CK.ColorSpace.SRGB }, diff, mac.width() * 4)
    await writeFile(path.join(out, 'Icons-0.own.diff.png'), di.encodeToBytes())
    const differing = 100 * off / n, mean = sum / n
    // The Mac's own outlines drawn here (tools/compare.mjs on <truth>/icons) are 0.13% and 0.29 off.
    check(differing < 0.3 && mean < 0.5, `the sheet at 2×, ${mac.width()}×${mac.height()}: ${differing.toFixed(2)}% of its pixels differ by more than 24 of 255, mean difference ${mean.toFixed(2)}, most ${most}`)
  }
} finally {
  await browser?.close()
}

console.log(failed ? `${failed} of ${checked} failed` : `all ${checked} passed`)
process.exit(failed ? 1 : 0)
