// Compares painted letters and justified text as the Mac draws them (PaintTruthTests.swift's
// Paints.bezzle, paints-mac.json and png/) with the browser's (this core and CanvasKit, in Node)
// and, where given, Windows' (bezzle-render's PNGs and its BEZZLE_TEXTS report):
//
// - painted texts: the colour of their letters, in a grid of 6 by 2 cells over each text's
//   frame (the mean colour of the pixels well inside the letters), as the greatest difference of
//   any cell from the Mac's, out of 255; and how much of the text's frame is inked;
// - justified texts: where each line breaks, and where each word of each line begins and ends
//   in the drawing (found from its ink: the nearest edge of ink to each of the Mac's), as the
//   greatest difference from the Mac's, in points, and how far each spread line's last word ends
//   from the frame's right edge; with BEZZLE_TEXTS_LETTERS, where each letter is set, from the
//   report (Windows).
//
// Fonts: "open", the open fonts the published page has (site/openfonts); "apple", Apple's fonts
// in site/fonts; "mac", those and this Mac's own Georgia, Arial and Helvetica, for checking how
// lines are spread in the very letters the Mac sets. --host and --wasm draw with another
// bezzle.mjs and core, such as those of an earlier commit, for a before and after.
//
//   node tools/paint-compare.mjs --truth <dir> [--fonts open|apple|mac] [--windows <dir of 00.png, 01.png>]
//        [--windows-texts <file>] [--host <bezzle.mjs>] [--wasm <core>] [--out <dir>] [--detail]

import { readFile, writeFile, readdir, mkdir } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
const { createBezzle } = await import(process.argv.includes('--host') ? path.resolve(process.argv[process.argv.indexOf('--host') + 1]) : '../site/bezzle.mjs')

const here = path.dirname(new URL(import.meta.url).pathname)
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const flag = (name) => process.argv.includes(`--${name}`)
const truthDir = arg('truth')
const fontsKind = arg('fonts', 'open')
const out = arg('out', path.join(here, '..', 'out', 'paint'))
const wasmPath = arg('wasm', path.join(here, '..', '.build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm'))
const scale = 2
await mkdir(out, { recursive: true })

const require = createRequire(import.meta.url)
const CanvasKitInit = require('canvaskit-wasm/bin/canvaskit.js')
const CK = await CanvasKitInit({ locateFile: (f) => require.resolve(`canvaskit-wasm/bin/${f}`) })

// MARK: The browser's drawing

// Helvetica's first face only, its Regular, from the Mac's collection.
const fontsDir = path.join(here, '..', 'site', fontsKind === 'open' ? 'openfonts' : 'fonts')
const manifest = JSON.parse(await readFile(path.join(fontsDir, 'manifest.json'), 'utf8'))
const fonts = {
  families: manifest.families,
  faces: await Promise.all(manifest.faces.map(async (f) => ({ ...f, data: await readFile(path.join(fontsDir, f.file)) }))),
  system: { ...manifest.system, data: await readFile(path.join(fontsDir, manifest.system.file)) },
  standsIn: manifest.standsIn ? [...Object.keys(manifest.standsIn), ...(manifest.system.standsIn ? ['System'] : [])] : undefined,
}
if (fontsKind === 'mac') {
  const own = { Georgia: { Regular: 'Georgia.ttf', Bold: 'Georgia Bold.ttf', Italic: 'Georgia Italic.ttf' },
                Arial: { Regular: 'Arial.ttf', Bold: 'Arial Bold.ttf', Italic: 'Arial Italic.ttf' } }
  for (const [family, faces] of Object.entries(own)) {
    fonts.families[family] = Object.keys(faces)
    for (const [face, file] of Object.entries(faces)) fonts.faces.push({ family, face, data: await readFile(path.join('/System/Library/Fonts/Supplemental', file)) })
  }
  fonts.families.Helvetica = ['Regular']
  fonts.faces.push({ family: 'Helvetica', face: 'Regular', data: await readFile('/System/Library/Fonts/Helvetica.ttc') })
}
const bz = await createBezzle({ CanvasKit: CK, wasm: await readFile(wasmPath), fonts, options: { trak: !!manifest.system.trak } })
const pkg = path.join(truthDir, 'Paints.bezzle')
const pictures = new Map()
for (const f of await readdir(path.join(pkg, 'images'))) pictures.set(f, await readFile(path.join(pkg, 'images', f)))
const opened = bz.open(await readFile(path.join(pkg, 'document.json')), pictures)
if (opened.error) throw new Error(opened.error)

function pixels(img) {
  return { w: img.width(), h: img.height(), data: img.readPixels(0, 0, { width: img.width(), height: img.height(), colorType: CK.ColorType.RGBA_8888, alphaType: CK.AlphaType.Unpremul, colorSpace: CK.ColorSpace.SRGB }) }
}
const decoded = async (file) => { const img = CK.MakeImageFromEncoded(await readFile(file)); const p = pixels(img); img.delete(); return p }

const browser = []
for (const index of [0, 1]) {
  const r = bz.render(index, scale)
  await writeFile(path.join(out, `Paints-${String(index).padStart(2, '0')}.${fontsKind}.web.png`), r.image.encodeToBytes())
  browser.push(pixels(r.image))
}
const browserTexts = Object.fromEntries(bz.texts().map((t) => [t.id, t]))

const mac = JSON.parse(await readFile(path.join(truthDir, 'paints-mac.json'), 'utf8')).samples
const macPNG = [await decoded(path.join(truthDir, 'png', 'Paints-00.png')), await decoded(path.join(truthDir, 'png', 'Paints-01.png'))]
const winDir = arg('windows')
const winPNG = winDir ? [await decoded(path.join(winDir, '00.png')), await decoded(path.join(winDir, '01.png'))] : null
const winReport = arg('windows-texts') ? JSON.parse(await readFile(arg('windows-texts'), 'utf8')) : null
const winTexts = winReport ? Object.fromEntries(winReport.samples.map((s) => [s.key.split('/')[1], s])) : {}

// MARK: Measures

const at = (p, x, y) => { const i = (y * p.w + x) * 4; return [p.data[i], p.data[i + 1], p.data[i + 2]] }
// How far a pixel is from the white of the artboards.
const inked = (c) => 255 * 3 - c[0] - c[1] - c[2]

/** The mean colour of the pixels well inside the letters, in a grid over the text's frame. */
function grid(p, frame, cols = 6, rows = 2) {
  const [fx, fy, fw, fh] = frame.map((v) => v * scale)
  const cells = []
  let ink = 0, all = 0
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const sum = [0, 0, 0]
      let n = 0
      for (let y = Math.floor(fy + fh * r / rows); y < Math.floor(fy + fh * (r + 1) / rows); y++) {
        for (let x = Math.floor(fx + fw * c / cols); x < Math.floor(fx + fw * (c + 1) / cols); x++) {
          if (x < 1 || y < 1 || x >= p.w - 1 || y >= p.h - 1) continue
          all++
          const k = at(p, x, y)
          if (inked(k) < 60) continue
          ink++
          // Well inside: the pixels around are inked too.
          if ([at(p, x - 1, y), at(p, x + 1, y), at(p, x, y - 1), at(p, x, y + 1)].some((q) => inked(q) < 60)) continue
          sum[0] += k[0]; sum[1] += k[1]; sum[2] += k[2]; n++
        }
      }
      cells.push(n > 20 ? sum.map((v) => v / n) : null)
    }
  }
  return { cells, ink: all ? ink / all : 0 }
}

function colourDifference(a, b) {
  let worst = 0, mean = 0, n = 0
  a.cells.forEach((c, i) => {
    const d = b.cells[i]
    if (!c || !d) return
    const e = Math.max(...c.map((v, k) => Math.abs(v - d[k])))
    worst = Math.max(worst, e); mean += e; n++
  })
  return { worst: Math.round(worst), mean: n ? Math.round(mean / n) : 0, cells: n }
}

/** Where the words of each line begin and end, from the ink in the line's band, in points from the text's left. */
function wordsOf(p, frame, lines, origin) {
  const [fx, fy, fw] = frame
  return lines.map((l) => {
    const top = Math.floor((fy + l[2]) * scale) + 1, bottom = Math.floor((fy + l[2] + l[3]) * scale) - 1
    const x0 = Math.max(Math.floor((fx - 4) * scale), 0), x1 = Math.min(Math.ceil((fx + fw + 4) * scale), p.w)
    const cols = []
    for (let x = x0; x < x1; x++) {
      let on = false
      for (let y = top; y < bottom && !on; y++) if (inked(at(p, x, y)) > 90) on = true
      cols.push(on)
    }
    // A gap of at least a fifth of the line's height between ink is a space between words.
    const least = Math.max(3, Math.round(l[3] * scale * 0.2))
    const words = []
    let start = -1, gap = 0
    cols.forEach((on, i) => {
      if (on) { if (start < 0) start = i; gap = 0 }
      else if (start >= 0) { gap++; if (gap >= least) { words.push([start, i - gap + 1]); start = -1; gap = 0 } }
    })
    if (start >= 0) words.push([start, cols.length - gap])
    // Every run of ink too, for finding the other drawing's word edges near these.
    const edges = { starts: [], ends: [] }
    cols.forEach((on, i) => {
      if (on && !cols[i - 1]) edges.starts.push((x0 + i) / scale - fx)
      if (on && !cols[i + 1]) edges.ends.push((x0 + i + 1) / scale - fx)
    })
    const out = words.map(([a, z]) => [(x0 + a) / scale - fx, (x0 + z) / scale - fx])
    out.edges = edges
    return out
  })
}

/** How far the other drawing's words begin and end from the Mac's: for each of the Mac's words,
 *  the nearest edge of ink in the other's line within 8 points, as the greatest difference; and
 *  how many found none. */
function wordDifference(a, b) {
  if (a.length !== b.length) return null
  let worst = 0, missed = 0
  a.forEach((words, i) => {
    const near = (x, list) => list.reduce((best, y) => (Math.abs(y - x) < Math.abs(best - x) ? y : best), Infinity)
    for (const [s, e] of words) {
      for (const [x, list] of [[s, b[i].edges.starts], [e, b[i].edges.ends]]) {
        const d = Math.abs(near(x, list) - x)
        if (d > 8) missed++; else worst = Math.max(worst, d)
      }
    }
  })
  return missed ? `${Math.round(worst * 100) / 100} (${missed} far)` : worst
}

const fmt = (v) => (v === null || v === undefined ? '-' : typeof v === 'number' ? (Math.round(v * 100) / 100).toString() : v)
const rows = []
for (const m of mac) {
  const id = m.key.split('/')[1]
  const board = m.board === 'Painted' ? 0 : 1
  // In its artboard's own coordinates.
  const frame = m.frame
  const row = { name: `${m.board}/${m.name}` }
  const b = browserTexts[id], w = winTexts[id]
  const macBreaks = m.lines.map((l) => l.slice(0, 2).join('-')).join(' ')
  const breaksOf = (t) => t ? t.lines.filter((l, i) => i < m.lines.length || l[1] > l[0]).map((l) => l.slice(0, 2).join('-')).join(' ') : null
  row.breaksWeb = b ? breaksOf(b) === macBreaks : null
  row.breaksWin = w ? breaksOf(w) === macBreaks : null
  if (m.painted) {
    const mg = grid(macPNG[board], frame)
    const bg = grid(browser[board], frame)
    row.colourWeb = colourDifference(mg, bg)
    row.inkMac = Math.round(mg.ink * 100), row.inkWeb = Math.round(bg.ink * 100)
    if (winPNG) { const wg = grid(winPNG[board], frame); row.colourWin = colourDifference(mg, wg); row.inkWin = Math.round(wg.ink * 100) }
  }
  if (m.align === 'justify') {
    const lines = m.lines.map((l) => [l[0], l[1], l[2] + m.offset, l[3]])
    const mw = wordsOf(macPNG[board], frame, lines)
    row.wordsWeb = wordDifference(mw, wordsOf(browser[board], frame, lines))
    if (winPNG) row.wordsWin = wordDifference(mw, wordsOf(winPNG[board], frame, lines))
    // The right edge of each spread line's last word, against the frame's right edge.
    const spread = m.lines.map((l, i) => i < m.lines.length - 1 && ![0x0A, 0x2028].includes(m.text.charCodeAt(l[1] - 1)))
    const edge = (words) => Math.max(0, ...words.map((ws, i) => (spread[i] && ws.length ? Math.abs(ws[ws.length - 1][1] - frame[2]) : 0)))
    row.edgeMac = edge(mw)
    row.edgeWeb = edge(wordsOf(browser[board], frame, lines))
    if (winPNG) row.edgeWin = edge(wordsOf(winPNG[board], frame, lines))
    if (w?.letters) {
      // Where each letter is set along its line, against the Mac's, by its place in the words.
      let worst = 0
      m.letters.forEach((xs, i) => {
        const theirs = new Map((w.letters[i] ?? []).map(([c, x]) => [c, x]))
        for (const [c, x] of xs) if (theirs.has(c) && !/\s/.test(m.text[c])) worst = Math.max(worst, Math.abs(theirs.get(c) - x))
      })
      row.lettersWin = worst
    }
    if (flag('detail')) {
      const r = (words) => words.map((ws) => ws.map((x) => x.map((v) => Math.round(v * 10) / 10)))
      row.detail = { mac: r(mw), web: r(wordsOf(browser[board], frame, lines)) }
      if (winPNG) row.detail.win = r(wordsOf(winPNG[board], frame, lines))
    }
  }
  if (flag('detail') && (row.breaksWeb === false || row.breaksWin === false)) {
    row.breaks = { mac: macBreaks, web: breaksOf(b), win: breaksOf(w) }
  }
  rows.push(row)
}

for (const r of rows) {
  const parts = [r.name.padEnd(28), `breaks web ${fmt(r.breaksWeb)} win ${fmt(r.breaksWin)}`]
  if (r.colourWeb) parts.push(`colour web ${r.colourWeb.worst}/${r.colourWeb.mean}` + (r.colourWin ? ` win ${r.colourWin.worst}/${r.colourWin.mean}` : '') + `  ink mac ${r.inkMac}% web ${r.inkWeb}%` + (r.inkWin !== undefined ? ` win ${r.inkWin}%` : ''))
  if ('wordsWeb' in r) parts.push(`words web ${fmt(r.wordsWeb)} win ${fmt(r.wordsWin)} pt  right edge mac ${fmt(r.edgeMac)} web ${fmt(r.edgeWeb)} win ${fmt(r.edgeWin)}` + (r.lettersWin !== undefined ? `  letters win ${fmt(r.lettersWin)} pt` : ''))
  console.log(parts.join('  '))
  if (r.breaks) console.log('    breaks', JSON.stringify(r.breaks))
  if (r.detail) console.log('   ', JSON.stringify(r.detail))
}
await writeFile(path.join(out, `paint-compare.${fontsKind}.json`), JSON.stringify(rows, null, 1))
