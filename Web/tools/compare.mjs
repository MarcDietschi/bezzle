// Draws the sample designs with the WebAssembly core and CanvasKit, in Node, and compares them
// with what the Mac's own app made of them (the truth: see WebTruthTests in the prototype notes):
// each artboard pixel by pixel, and each text by where its lines break and how big it is.
//
//   node tools/compare.mjs --truth <dir with truth.json and PNGs> --designs <dir of .bezzle> [--no-trak] [--no-opsz]

import { readFile, writeFile, readdir, mkdir } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
import { createBezzle } from '../site/bezzle.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const flag = (name) => process.argv.includes(`--${name}`)
const truthDir = arg('truth'), designsDir = arg('designs')
const out = arg('out', path.join(here, '..', 'out'))
const wasmPath = arg('wasm', path.join(here, '..', '.build/out/Products/Debug-webassembly-wasm32/BezzleCore.wasm'))
const scale = Number(arg('scale', '2'))
await mkdir(out, { recursive: true })

const require = createRequire(import.meta.url)
const CanvasKitInit = require('canvaskit-wasm/bin/canvaskit.js')
const CK = await CanvasKitInit({ locateFile: (f) => require.resolve(`canvaskit-wasm/bin/${f}`) })

const fontsDir = path.join(here, '..', 'site', 'fonts')
const manifest = JSON.parse(await readFile(path.join(fontsDir, 'manifest.json'), 'utf8'))
const fonts = {
  families: manifest.families,
  faces: await Promise.all(manifest.faces.map(async (f) => ({ ...f, data: await readFile(path.join(fontsDir, f.file)) }))),
  system: { ...manifest.system, data: await readFile(path.join(fontsDir, manifest.system.file)) },
}

const bz = await createBezzle({ CanvasKit: CK, wasm: await readFile(wasmPath), fonts, options: { trak: !flag('no-trak'), opsz: !flag('no-opsz') } })
const truth = JSON.parse(await readFile(path.join(truthDir, 'truth.json'), 'utf8'))

function pixels(img) {
  return img.readPixels(0, 0, { width: img.width(), height: img.height(), colorType: CK.ColorType.RGBA_8888, alphaType: CK.AlphaType.Unpremul, colorSpace: CK.ColorSpace.SRGB })
}

const report = { boards: [], texts: [] }
for (const [name, t] of Object.entries(truth)) {
  const pkg = path.join(designsDir, `${name}.bezzle`)
  const json = await readFile(path.join(pkg, 'document.json'))
  const pictures = new Map()
  try {
    for (const f of await readdir(path.join(pkg, 'images'))) pictures.set(f, await readFile(path.join(pkg, 'images', f)))
  } catch {}
  const opened = bz.open(json, pictures)
  if (opened.error) { console.log(name, 'could not open:', opened.error); continue }

  for (const b of t.boards) {
    const r = bz.render(b.index, scale)
    const web = r.image
    const png = web.encodeToBytes()
    await writeFile(path.join(out, `${name}-${b.index}.web.png`), png)
    const mac = CK.MakeImageFromEncoded(await readFile(path.join(truthDir, b.file)))
    const entry = { design: name, board: b.name, index: b.index, coreMs: Math.round(r.coreMs), totalMs: Math.round(r.totalMs) }
    if (mac.width() !== web.width() || mac.height() !== web.height()) {
      entry.size = `mac ${mac.width()}×${mac.height()}, web ${web.width()}×${web.height()}`
    } else {
      const a = pixels(mac), w = pixels(web)
      const diff = new Uint8Array(a.length)
      let sum = 0, off = 0
      for (let k = 0; k < a.length; k += 4) {
        const d = Math.max(Math.abs(a[k] - w[k]), Math.abs(a[k + 1] - w[k + 1]), Math.abs(a[k + 2] - w[k + 2]))
        sum += d
        if (d > 24) off++
        // Grey where alike, red where not.
        const g = (a[k] + a[k + 1] + a[k + 2]) / 3 * 0.35 + 160
        diff.set(d > 24 ? [255, 40, 40, 255] : [g, g, g, 255], k)
      }
      const n = a.length / 4
      entry.meanDiff = +(sum / n).toFixed(2)
      entry.differing = +(100 * off / n).toFixed(2)
      const di = CK.MakeImage({ width: mac.width(), height: mac.height(), alphaType: CK.AlphaType.Unpremul, colorType: CK.ColorType.RGBA_8888, colorSpace: CK.ColorSpace.SRGB }, diff, mac.width() * 4)
      await writeFile(path.join(out, `${name}-${b.index}.diff.png`), di.encodeToBytes())
      di.delete()
    }
    mac.delete()
    report.boards.push(entry)
  }

  const webTexts = new Map(bz.texts().map((x) => [x.id, x]))
  for (const m of t.texts) {
    const w = webTexts.get(m.id)
    if (!w) continue
    const macBreaks = m.lines.map((l) => l[1]).join(','), webBreaks = w.lines.map((l) => l[1]).join(',')
    report.texts.push({
      design: name, text: m.text.slice(0, 40), family: m.family, face: m.face, size: m.size, sizing: m.sizing,
      lines: [m.lines.length, w.lines.length], sameBreaks: macBreaks === webBreaks,
      dWidth: +(w.used[0] - m.used[0]).toFixed(2), dHeight: +(w.used[1] - m.used[1]).toFixed(2),
      dNatural: +(w.natural - m.natural).toFixed(2), dBaseline: +(w.firstBaseline - m.firstBaseline).toFixed(2),
      dFitted: [+(w.fitted[0] - m.fitted[0]).toFixed(2), +(w.fitted[1] - m.fitted[1]).toFixed(2)],
    })
  }
}

await writeFile(path.join(out, 'report.json'), JSON.stringify(report, null, 1))
const T = report.texts
const same = T.filter((x) => x.sameBreaks).length
const widthWithin = (d) => T.filter((x) => Math.abs(x.dNatural) <= d).length
console.log(`artboards: ${report.boards.length}`)
for (const b of report.boards) console.log(`  ${b.design} · ${b.board}: ${b.size ?? `${b.differing}% of pixels differ, mean ${b.meanDiff}`}  (core ${b.coreMs} ms, all ${b.totalMs} ms)`)
console.log(`texts: ${T.length}; lines break alike in ${same}; multi-line ${T.filter((x) => x.lines[0] > 1).length}, alike ${T.filter((x) => x.lines[0] > 1 && x.sameBreaks).length}`)
console.log(`  natural width within 0 pt: ${widthWithin(0)}, 1 pt: ${widthWithin(1)}, 3 pt: ${widthWithin(3)}`)
console.log(`  height alike: ${T.filter((x) => Math.abs(x.dHeight) < 0.01).length}, first baseline alike: ${T.filter((x) => Math.abs(x.dBaseline) < 0.01).length}`)
