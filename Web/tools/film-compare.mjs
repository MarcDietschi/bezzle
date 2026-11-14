// Shows the films of the test designs with the WebAssembly core and CanvasKit and compares them
// with what the Mac made of them (the truth: tools/FilmTruthTests.swift, see Web/README.md):
// where the film's arithmetic puts each piece at each moment, number by number, and each frame
// pixel by pixel. And measures how many frames a second a page keeps while a film plays.
//
//   node tools/film-compare.mjs --truth <dir holding films/> [--out <dir>] [--only Depth,Lines]
//        [--browser] [--fps [seconds]] [--chrome <path>] [--profile <dir>] [--wasm <path>]
//
// Without --browser the frames are made in Node, on the processor, where there is no WebGL: a
// shader fill then shows its picture, so a film with one that moves is only right in a browser.
// With --browser they are made by the page's own film.mjs in a headless Chromium (Playwright's,
// from ~/Library/Caches/ms-playwright, or --chrome), once on the graphics card and once on the
// processor. --fps plays each film there as the page plays it and counts.

import { readFile, writeFile, readdir, mkdir, mkdtemp, rm, stat } from 'node:fs/promises'
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import { spawn } from 'node:child_process'
import { tmpdir, homedir } from 'node:os'
import path from 'node:path'
import { createBezzle } from '../site/bezzle.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 && process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[i + 1] : fallback }
const flag = (name) => process.argv.includes(`--${name}`)
const truthDir = path.join(arg('truth'), 'films')
const out = arg('out', path.join(here, '..', 'out', 'films'))
const wasmPath = arg('wasm', path.join(here, '..', '.build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm'))
const only = arg('only')?.split(',')
await mkdir(out, { recursive: true })

const require = createRequire(import.meta.url)
const canvaskitDir = path.dirname(require.resolve('canvaskit-wasm/bin/canvaskit.js'))
const CK = await require('canvaskit-wasm/bin/canvaskit.js')({ locateFile: (f) => path.join(canvaskitDir, f) })
const films = JSON.parse(await readFile(path.join(truthDir, 'films.json'), 'utf8')).filter((f) => !only || only.includes(f.name))

const info = (w, h) => ({ width: w, height: h, colorType: CK.ColorType.RGBA_8888, alphaType: CK.AlphaType.Unpremul, colorSpace: CK.ColorSpace.SRGB })
const pixels = (img) => img.readPixels(0, 0, info(img.width(), img.height()))

// Two frames, pixel by pixel: the share of pixels more than 24 levels apart in a channel, and
// how far apart they are on average. Writes a picture of where: grey where alike, red where not.
async function compared(mac, web, name) {
  if (mac.width() !== web.width() || mac.height() !== web.height()) return { size: `mac ${mac.width()}×${mac.height()}, web ${web.width()}×${web.height()}` }
  const a = pixels(mac), w = pixels(web)
  const diff = new Uint8Array(a.length)
  let sum = 0, off = 0
  for (let k = 0; k < a.length; k += 4) {
    const d = Math.max(Math.abs(a[k] - w[k]), Math.abs(a[k + 1] - w[k + 1]), Math.abs(a[k + 2] - w[k + 2]))
    sum += d
    if (d > 24) off++
    const g = (a[k] + a[k + 1] + a[k + 2]) / 3 * 0.35 + 160
    diff.set(d > 24 ? [255, 40, 40, 255] : [g, g, g, 255], k)
  }
  const n = a.length / 4
  const picture = CK.MakeImage(info(mac.width(), mac.height()), diff, mac.width() * 4)
  await writeFile(path.join(out, `${name}.diff.png`), picture.encodeToBytes())
  picture.delete()
  return { differing: +(100 * off / n).toFixed(3), meanDiff: +(sum / n).toFixed(3) }
}

// Where a map puts a point, as Bezzle/Model/Film.swift's FilmMap does.
const through = (m, x, y) => { const w = m[6] * x + m[7] * y + m[8]; return w > 1e-6 ? [(m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w] : null }

// The film's arithmetic here against the Mac's: the farthest any piece's corner of the artboard
// lands from where the Mac has it, in points, and the largest difference in how solid, how
// blurred and how high a piece is.
function arithmetic(truth, web, size) {
  const worst = { points: 0, opacity: 0, blur: 0, height: 0, order: JSON.stringify(truth.order) === JSON.stringify(web.order), pieces: truth.pieces.length === web.pieces.length }
  truth.pieces.forEach((p, k) => {
    const q = web.pieces[k]
    if (!q || q.key !== p.key || q.changes !== p.changes) { worst.pieces = false; return }
    worst.opacity = Math.max(worst.opacity, Math.abs(p.opacity - q.opacity))
    worst.blur = Math.max(worst.blur, Math.abs(p.blur - q.blur))
    worst.height = Math.max(worst.height, Math.abs(p.height - q.height))
    for (const [x, y] of [[0, 0], [size[0], 0], [size[0], size[1]], [0, size[1]], [size[0] / 2, size[1] / 2]]) {
      const a = through(p.map, x, y), b = through(q.map, x, y)
      if (!a !== !b) worst.points = Infinity
      else if (a && b) worst.points = Math.max(worst.points, Math.hypot(a[0] - b[0], a[1] - b[1]))
    }
  })
  return worst
}

async function picturesOf(pkg) {
  const pictures = new Map()
  try {
    for (const f of await readdir(path.join(truthDir, pkg, 'images'))) pictures.set(f, await readFile(path.join(truthDir, pkg, 'images', f)))
  } catch {}
  return pictures
}

const stamp = (t) => String(Math.round(t * 1000)).padStart(4, '0')
const mean = (list) => (list.length ? list.reduce((a, b) => a + b, 0) / list.length : 0)
const report = { frames: [], films: [], fps: [] }

function summed(kind) {
  for (const film of films) {
    const mine = report.frames.filter((f) => f.film === film.name && f.kind === kind && f.differing !== undefined)
    if (!mine.length) continue
    const entry = { film: film.name, kind, frames: mine.length, differing: +mean(mine.map((f) => f.differing)).toFixed(3), meanDiff: +mean(mine.map((f) => f.meanDiff)).toFixed(3),
      worst: Math.max(...mine.map((f) => f.differing)), points: Math.max(...mine.map((f) => f.points ?? 0)) }
    report.films.push(entry)
    console.log(`${film.name} (${kind}): ${entry.frames} frames, ${entry.differing}% of pixels differ on average (worst frame ${entry.worst}%), mean difference ${entry.meanDiff} of 255; ` +
      `arithmetic within ${entry.points.toExponential(1)} pt of the Mac's`)
  }
}

// MARK: In Node

if (!flag('browser') && !flag('fps')) {
  const fontsDir = path.join(here, '..', 'site', 'fonts')
  const manifest = JSON.parse(await readFile(path.join(fontsDir, 'manifest.json'), 'utf8'))
  const fonts = {
    families: manifest.families,
    faces: await Promise.all(manifest.faces.map(async (f) => ({ ...f, data: await readFile(path.join(fontsDir, f.file)) }))),
    system: { ...manifest.system, data: await readFile(path.join(fontsDir, manifest.system.file)) },
  }
  const bz = await createBezzle({ CanvasKit: CK, wasm: await readFile(wasmPath), fonts, options: { trak: true } })
  for (const film of films) {
    const opened = bz.open(await readFile(path.join(truthDir, film.package, 'document.json')), await picturesOf(film.package))
    if (opened.error) { console.log(film.name, 'could not open:', opened.error); continue }
    for (const b of film.boards) {
      const listed = opened.boards.find((o) => o.index === b.index)
      const f = bz.film(b.index)
      if (!f) { console.log(film.name, b.name, 'has no film here'); continue }
      const same = Math.abs(f.length - b.length) < 1e-9 && f.once === b.once && f.backdrop.every((v, k) => Math.abs(v - b.backdrop[k] * b.backdrop[3]) < 1e-9)
        && listed?.film?.length === f.length && listed?.film?.once === f.once
      if (!same) console.log(film.name, b.name, 'film differs:', JSON.stringify(f), 'against', JSON.stringify({ length: b.length, once: b.once, backdrop: b.backdrop }))
      const before = bz.held()
      for (const frame of b.frames) {
        const worst = arithmetic(frame, bz.filmPlacements(frame.t), b.size)
        const t0 = performance.now()
        const web = bz.filmImage(frame.t, b.pixels[0], b.pixels[1], f.backdrop)
        const ms = performance.now() - t0
        const name = `${film.name}-${b.index}-${stamp(frame.t)}`
        await writeFile(path.join(out, `${name}.node.png`), web.encodeToBytes())
        const mac = CK.MakeImageFromEncoded(await readFile(path.join(truthDir, frame.file)))
        const entry = { film: film.name, board: b.name, t: frame.t, kind: 'node', ms: Math.round(ms), ...await compared(mac, web, `${name}.node`), points: worst.points,
          opacity: worst.opacity, blur: worst.blur, height: worst.height, order: worst.order && worst.pieces }
        mac.delete(); web.delete()
        report.frames.push(entry)
        console.log(`${name}: ${entry.differing}% differ, mean ${entry.meanDiff}, ${entry.ms} ms` + (entry.order ? '' : ', ORDER OR PIECES DIFFER') +
          (entry.points > 1e-6 || entry.opacity > 1e-9 || entry.blur > 1e-9 ? `, arithmetic off by ${entry.points} pt, opacity ${entry.opacity}, blur ${entry.blur}` : ''))
      }
      // A film lets go of what it made: after it, the page holds what it held before.
      bz.filmClose()
      const after = bz.held()
      if (after.made > before.made || after.shaderFrames > before.shaderFrames) console.log(film.name, b.name, 'pictures kept after the film:', JSON.stringify(before), '→', JSON.stringify(after))
    }
  }
  summed('node')
  await writeFile(path.join(out, 'report.json'), JSON.stringify(report, null, 1))
  process.exit(0)
}

// MARK: In a headless browser

const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png' }
const roots = { '/site/': path.join(here, '..', 'site'), '/canvaskit/': canvaskitDir, '/truth/': truthDir }

const HARNESS = `<!doctype html><meta charset="utf-8"><title>Film</title><body><div id="stage"></div>
<script type="module">
import { createBezzle } from '/site/bezzle.mjs'
import { createScreen, BREATH } from '/site/film.mjs'
try {
  await new Promise((ok, fail) => { const s = document.createElement('script'); s.src = '/canvaskit/canvaskit.js'; s.onload = ok; s.onerror = fail; document.head.append(s) })
  const CK = await window.CanvasKitInit({ locateFile: (f) => '/canvaskit/' + f })
  const bytes = async (url) => new Uint8Array(await (await fetch(url)).arrayBuffer())
  const manifest = await (await fetch('/site/fonts/manifest.json')).json()
  const fonts = {
    families: manifest.families,
    faces: await Promise.all(manifest.faces.map(async (f) => ({ ...f, data: await bytes('/site/fonts/' + f.file) }))),
    system: { ...manifest.system, data: await bytes('/site/fonts/' + manifest.system.file) },
  }
  const bz = await createBezzle({ CanvasKit: CK, wasm: await bytes('/core.wasm'), fonts, options: { trak: true } })
  const screens = { gpu: createScreen({ CanvasKit: CK, bz }), cpu: createScreen({ CanvasKit: CK, bz, software: true }) }
  document.getElementById('stage').append(screens.gpu.canvas, screens.cpu.canvas)
  window.harness = {
    async open(pkg, images) {
      const pictures = new Map(await Promise.all(images.map(async (n) => [n, await bytes('/truth/' + pkg + '/images/' + encodeURIComponent(n))])))
      return bz.open(await bytes('/truth/' + pkg + '/document.json'), pictures)
    },
    film: (index) => bz.film(index),
    close: () => bz.filmClose(),
    held: () => bz.held(),
    placements: (t) => bz.filmPlacements(t),
    frame(kind, t, w, h, backdrop) {
      const s = screens[kind]
      s.size(w, h)
      const took = s.show(t, backdrop, false)
      return { png: s.canvas.toDataURL('image/png'), took, onGraphicsCard: s.onGraphicsCard }
    },
    // The film played as the page plays it, from the start and round and round, for some seconds.
    async fps(kind, w, h, backdrop, length, seconds) {
      const s = screens[kind]
      s.size(w, h)
      // As the page does once an artboard with a film shows, before anyone plays it: every
      // picture that stays is made first, one at a time, and the graphics card given time for them.
      while (s.warm() > 0) await new Promise((ok) => setTimeout(ok, 20))
      await new Promise((ok) => setTimeout(ok, 1500))
      return new Promise((done) => {
        const began = performance.now()
        let frames = 0, core = 0, picture = 0, draw = 0, drawn = 0, last = began, longest = 0, longestAt = 0, late = 0
        const step = (now) => {
          const at = Math.max(now - began, 0) / 1000
          if (at >= seconds) return done({ frames, seconds: at, fps: frames / at, coreMs: core / frames, pictureMs: picture / frames, drawMs: draw / frames, drawn, longestMs: longest, longestAt, late, onGraphicsCard: s.onGraphicsCard })
          const took = s.show(Math.min(at % (length + BREATH), length), backdrop, true)
          frames++; core += took.coreMs; picture += took.pictureMs; draw += took.drawMs; drawn += took.drawn
          if (frames > 1) { if (now - last > longest) { longest = now - last; longestAt = at } if (now - last > 25) late++ }
          last = now
          requestAnimationFrame(step)
        }
        requestAnimationFrame(step)
      })
    },
    card() {
      const gl = document.createElement('canvas').getContext('webgl')
      const ext = gl?.getExtension('WEBGL_debug_renderer_info')
      return gl ? (ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)) : 'no WebGL'
    },
  }
  window.ready = true
} catch (e) { window.failed = String(e?.stack ?? e) }
</script>`

const server = createServer(async (req, res) => {
  try {
    const url = decodeURIComponent(new URL(req.url, 'http://x').pathname)
    let file = null
    if (url === '/harness.html') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end(HARNESS) }
    if (url === '/core.wasm') file = wasmPath
    for (const [prefix, root] of Object.entries(roots)) if (url.startsWith(prefix)) file = path.join(root, path.normalize(url.slice(prefix.length)).replace(/^(\.\.[/\\])+/, ''))
    if (!file || !(await stat(file)).isFile()) throw new Error('none')
    res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' })
    res.end(await readFile(file))
  } catch { res.writeHead(404); res.end() }
})
await new Promise((ok) => server.listen(0, '127.0.0.1', ok))
const origin = `http://127.0.0.1:${server.address().port}`

async function findChrome() {
  if (arg('chrome')) return arg('chrome')
  const cache = path.join(homedir(), 'Library/Caches/ms-playwright')
  for (const dir of (await readdir(cache).catch(() => [])).filter((d) => d.startsWith('chromium_headless_shell-')).sort().reverse()) {
    for (const sub of await readdir(path.join(cache, dir)).catch(() => [])) {
      const bin = path.join(cache, dir, sub, 'chrome-headless-shell')
      if (await stat(bin).then((s) => s.isFile(), () => false)) return bin
    }
  }
  throw new Error('No headless Chromium found: give one with --chrome <path>.')
}

const profile = arg('profile') ?? await mkdtemp(path.join(tmpdir(), 'bezzle-film-'))
await mkdir(profile, { recursive: true })
const chrome = spawn(await findChrome(), ['--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
  '--enable-gpu', '--use-angle=metal', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader', '--window-size=1400,1000', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] })
const done = async (code) => {
  chrome.kill()
  server.close()
  if (!arg('profile')) await rm(profile, { recursive: true, force: true }).catch(() => {})
  process.exit(code)
}
const wsUrl = await new Promise((ok, fail) => {
  let said = ''
  chrome.stderr.on('data', (d) => { said += d; const m = said.match(/DevTools listening on (ws:\/\/\S+)/); if (m) ok(m[1]) })
  chrome.on('exit', () => fail(new Error('Chromium did not start: ' + said.slice(0, 600))))
  setTimeout(() => fail(new Error('Chromium did not answer in time')), 30000)
}).catch(async (e) => { console.error(String(e)); await done(1) })

const ws = new WebSocket(wsUrl)
await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail })
let nextId = 1
const waiting = new Map()
ws.onmessage = (e) => {
  const m = JSON.parse(e.data)
  if (m.id && waiting.has(m.id)) { const w = waiting.get(m.id); waiting.delete(m.id); m.error ? w.fail(new Error(m.error.message)) : w.ok(m.result) }
  else if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type)) console.log('[page]', m.params.args.map((a) => a.value ?? a.description ?? '').join(' ').slice(0, 400))
  else if (m.method === 'Runtime.exceptionThrown') console.log('[page]', (m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text).slice(0, 600))
}
const send = (method, params = {}, sessionId) => new Promise((ok, fail) => { const id = nextId++; waiting.set(id, { ok, fail }); ws.send(JSON.stringify({ id, method, params, sessionId })) })
const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
await send('Runtime.enable', {}, sessionId)
await send('Page.enable', {}, sessionId)
async function page(expression) {
  const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId)
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text)
  return r.result.value
}
await send('Page.navigate', { url: origin + '/harness.html' }, sessionId)
for (let k = 0; ; k++) {
  const state = await page('window.ready ? "ready" : window.failed ?? ""').catch(() => '')
  if (state === 'ready') break
  if (state || k > 600) { console.error('The page did not start:', state || 'no answer'); await done(1) }
  await new Promise((ok) => setTimeout(ok, 200))
}
const call = (fn, ...args) => page(`window.harness.${fn}(${args.map((a) => JSON.stringify(a)).join(',')})`)
const card = await call('card')
console.log('Headless Chromium, WebGL on:', card)
report.card = card

for (const film of films) {
  const opened = await call('open', film.package, [...(await picturesOf(film.package)).keys()])
  if (opened.error) { console.log(film.name, 'could not open:', opened.error); continue }
  for (const b of film.boards) {
    const f = await call('film', b.index)
    if (!f) { console.log(film.name, b.name, 'has no film here'); continue }
    if (flag('browser')) {
      for (const kind of ['gpu', 'cpu']) {
        const before = await call('held')
        for (const frame of b.frames) {
          const worst = arithmetic(frame, await call('placements', frame.t), b.size)
          const made = await call('frame', kind, frame.t, b.pixels[0], b.pixels[1], f.backdrop)
          const name = `${film.name}-${b.index}-${stamp(frame.t)}`
          const png = Buffer.from(made.png.slice(made.png.indexOf(',') + 1), 'base64')
          await writeFile(path.join(out, `${name}.${kind}.png`), png)
          const mac = CK.MakeImageFromEncoded(await readFile(path.join(truthDir, frame.file))), web = CK.MakeImageFromEncoded(png)
          const entry = { film: film.name, board: b.name, t: frame.t, kind, onGraphicsCard: made.onGraphicsCard, coreMs: +made.took.coreMs.toFixed(1), drawMs: +made.took.drawMs.toFixed(1),
            ...await compared(mac, web, `${name}.${kind}`), points: worst.points, opacity: worst.opacity, blur: worst.blur, order: worst.order && worst.pieces }
          mac.delete(); web.delete()
          report.frames.push(entry)
          console.log(`${name} (${kind}${kind === 'gpu' && !made.onGraphicsCard ? ', but on the processor' : ''}): ${entry.differing}% differ, mean ${entry.meanDiff}` + (entry.order ? '' : ', ORDER OR PIECES DIFFER'))
        }
        const after = await call('held')
        if (kind === 'cpu') {
          await call('close')
          const closed = await call('held')
          console.log(`${film.name}: pictures held before the film ${before.made}, with it ${after.made}, after it ${closed.made}; shader frames ${closed.shaderFrames}`)
          await call('film', b.index)
        }
      }
    }
    if (flag('fps')) {
      const seconds = Number(arg('fps', '6'))
      for (const kind of ['gpu', 'cpu']) {
        const before = (await call('held')).spent
        const r = await call('fps', kind, b.pixels[0], b.pixels[1], f.backdrop, f.length, seconds)
        const after = (await call('held')).spent
        r.shaderMs = (after.shaders - before.shaders) / r.frames
        const entry = { film: film.name, board: b.name, kind, pixels: b.pixels, onGraphicsCard: r.onGraphicsCard, fps: +r.fps.toFixed(1), frames: r.frames, coreMs: +r.coreMs.toFixed(2), shaderMs: +r.shaderMs.toFixed(2), pictureMs: +r.pictureMs.toFixed(2), drawMs: +r.drawMs.toFixed(2),
          drawn: r.drawn, longestMs: +r.longestMs.toFixed(1), longestAt: +r.longestAt.toFixed(2), late: r.late }
        report.fps.push(entry)
        console.log(`${film.name} playing at ${b.pixels[0]}×${b.pixels[1]} (${kind === 'gpu' && r.onGraphicsCard ? 'graphics card' : 'processor'}): ${entry.fps} frames a second over ${r.seconds.toFixed(1)} s; ` +
          `each frame ${entry.coreMs} ms in the core (${entry.shaderMs} ms of it shaders drawn), ${entry.pictureMs} ms making pictures and ${entry.drawMs} ms placing them; ${entry.drawn} pictures made; longest wait for a frame ${entry.longestMs} ms (${entry.longestAt} s in), ${entry.late} frames more than 25 ms after the one before`)
      }
    }
    await call('close')
  }
}
if (flag('browser')) { summed('gpu'); summed('cpu') }
await writeFile(path.join(out, flag('browser') ? 'report.browser.json' : 'report.fps.json'), JSON.stringify(report, null, 1))
await done(0)
