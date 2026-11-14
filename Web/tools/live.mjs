// Tests a design's live room in the browser, where the page only watches (site/live.mjs,
// site/share.mjs' follow, the core's WebLive), against what Macs said to one who only watches:
// LiveTruthTests writes <truth>/live/live.json, two real rooms on the Mac, everything a watcher
// was sent, and what each Mac showed of the other meanwhile.
//
//  1. The core reads the Macs' words as the Macs read them: the same people in the same pencils,
//     hands, tools, the outline of each layer held, the loop of a wink; the same design after
//     each change, to the byte; pencils and loops worked out alike for other rooms and seeds.
//  2. With --relay, on a relay of this Mac's own (cd Relay && npx wrangler dev --port 8791): the
//     page (site/shared.html) in a headless Chromium opens that design, stand-ins say the Macs'
//     words in its room, and the page shows them: tokens in the bar, hands and outlines over the
//     artboard in their pencils, a wink, a change as it is made and not drawn twice when its
//     record follows, someone silent as away and then gone. And the page says nothing in the
//     room but that it is still there, in the bytes the Mac was shown to take.
//
//   node tools/live.mjs --truth <dir> [--relay http://127.0.0.1:8791] [--shots <dir>] [--chrome <path>] [--wasm <core>]

import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
import { createBezzle } from '../site/bezzle.mjs'
import { ShareKeys, SharedRoom, Relay, STILL_THERE, sha256hex, b64url, partKey } from '../site/share.mjs'
import { launch } from './headless.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const web = path.join(here, '..')
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const truthDir = arg('truth')
const relayURL = arg('relay')
const shots = arg('shots')
const wasmPath = arg('wasm', path.join(web, '.build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm'))
if (!truthDir) { console.error('Give the Mac’s truth: --truth <dir> (LiveTruthTests writes <dir>/live/live.json)'); process.exit(2) }
const truth = JSON.parse(await readFile(path.join(truthDir, 'live', 'live.json'), 'utf8'))

const require = createRequire(import.meta.url)
const CK = await require('canvaskit-wasm/bin/canvaskit.js')({ locateFile: (f) => require.resolve(`canvaskit-wasm/bin/${f}`) })
const fontsDir = path.join(web, 'site', 'fonts')
const manifest = JSON.parse(await readFile(path.join(fontsDir, 'manifest.json'), 'utf8'))
const fonts = {
  families: manifest.families,
  faces: await Promise.all(manifest.faces.map(async (f) => ({ ...f, data: await readFile(path.join(fontsDir, f.file)) }))),
  system: { ...manifest.system, data: await readFile(path.join(fontsDir, manifest.system.file)) },
}
const bz = await createBezzle({ CanvasKit: CK, wasm: await readFile(wasmPath), fonts, options: { trak: true } })

let failed = 0, checked = 0
const check = (ok, what) => { checked++; console.log(`${ok ? '  ok ' : '  FAIL'} ${what}`); if (!ok) failed++ }
const fromB64 = (s) => Uint8Array.from(Buffer.from(s, 'base64'))
const close = (a, b, by = 1e-9) => Math.abs(a - b) <= by * Math.max(1, Math.abs(a), Math.abs(b))
const closeAll = (a, b, by) => Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((v, i) => close(v, b[i], by))
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms))
async function until(test, patience = 8000) {
  const began = Date.now()
  for (;;) {
    const got = await test()
    if (got) return got
    if (Date.now() - began > patience) return null
    await sleep(60)
  }
}

/** What a kind of message is to the page. */
const shownAs = { hello: 'hello', presence: 'presence', wink: 'wink', changes: 'changes' }
/** Someone as the Mac showed them, but for whether they are away: the page also takes silence for that. */
const butAway = (mac) => { const { away, ...rest } = mac; return rest }

/** How someone the Mac showed differs from the one the browser shows; '' when not at all. */
function differs(mac, own) {
  if (!own) return 'not there'
  const off = []
  for (const key of ['name', 'initial', 'doing', 'away', 'tool', 'timeZone']) if (key in mac && mac[key] !== own[key]) off.push(`${key} ${own[key]}, on the Mac ${mac[key]}`)
  if (!closeAll(mac.color, own.color)) off.push(`pencil ${own.color}, on the Mac ${mac.color}`)
  if ('view' in mac) {
    if (!closeAll(mac.view, own.view)) off.push(`view ${own.view}, on the Mac ${mac.view}`)
    if (('pointer' in mac) !== ('pointer' in own) || (mac.pointer && !closeAll(mac.pointer, own.pointer))) off.push(`pointer ${own.pointer}, on the Mac ${mac.pointer}`)
    const holds = (own.holds ?? []).map((h) => h.points)
    if (holds.length !== mac.holds.length || !holds.every((h, i) => closeAll(h, mac.holds[i]))) off.push(`holds ${JSON.stringify(holds)}, on the Mac ${JSON.stringify(mac.holds)}`)
  }
  return off.join('; ')
}

// MARK: 1, the core reads what the Macs said

console.log('The core, with what the Macs said')
check(Buffer.compare(Buffer.from(STILL_THERE), Buffer.from(truth.stillThere, 'base64')) === 0, 'what the page says to say it still watches is what the Mac was shown to take')
bz.openShared([truth.design], 'watcher')
let said = 0, packed = 0
for (const step of truth.steps) {
  let wink = null, misread = []
  for (const e of step.events) {
    if (e.kind === 'welcome') bz.liveClear()
    else if (e.kind === 'left') bz.liveLeft(e.peer)
    else if (e.kind === 'message') {
      said++
      if (e.packed) packed++
      const r = bz.liveMessage(e.peer, fromB64(e.plain))
      if (r.kind !== (shownAs[e.says] ?? 'other')) misread.push(`${e.says} read as ${r.kind}`)
      if (r.kind === 'wink') wink = r
      if (r.kind === 'changes') bz.receive([r.record])
    }
  }
  const people = bz.livePeople()
  const off = step.people.map((mac) => [mac.name, differs(mac, people.find((p) => p.name === mac.name))]).filter(([, d]) => d)
  check(!misread.length && !off.length && people.length === step.people.length,
    `${step.name}: ${step.events.filter((e) => e.kind === 'message').map((e) => e.says).join(', ') || 'nothing said'}; ${people.length} shown as on the Mac`
    + (misread.length ? `: ${misread.join(', ')}` : '') + off.map(([n, d]) => `: ${n}: ${d}`).join('') + (people.length !== step.people.length ? `: ${people.length} people, on the Mac ${step.people.length}` : ''))
  if (step.document) {
    const own = new TextDecoder().decode(bz.documentBytes())
    let at = 0
    while (at < own.length && own[at] === step.document[at]) at++
    check(own === step.document, own === step.document ? `  the design after it is the Mac's, to the byte (${own.length} bytes)`
      : `  the design after it: first difference at ${at}: mac …${step.document.slice(at - 60, at + 60)}… web …${own.slice(at - 60, at + 60)}…`)
  }
  if (step.wink) {
    const by = step.people.find((p) => p.replica === step.wink.replica)
    check(!!wink && closeAll(wink.at, step.wink.at) && closeAll(wink.color, by.color) && wink.points.length === truth.loops[0].points.length
      && closeAll(wink.drawn, truth.shown.map((s) => s[0]), 1e-12) && closeAll(wink.alpha, truth.shown.map((s) => s[1]), 1e-12),
      `  the wink is where the Mac has it, in ${by.name}'s pencil, drawn and fading at the Mac's pace (${wink?.drawn.length} moments)`)
  }
}
check(said > 0 && packed > 0, `${said} messages read, ${packed} of them packed (LZFSE)`)
const boards = bz.livePeople()
{
  // Where things lie among the artboards, from the steps before: checked on the first Mac's hand-made words.
  const hand = truth.steps.find((s) => s.name.startsWith('a hand over the first artboard'))
  bz.openShared([truth.design], 'watcher')
  bz.liveClear()
  for (const s of truth.steps.slice(0, truth.steps.indexOf(hand) + 1)) for (const e of s.events) if (e.kind === 'message') bz.liveMessage(e.peer, fromB64(e.plain))
  const anna = bz.livePeople().find((p) => p.name === 'Anna')
  check(anna?.board === 0 && anna.holds.length === 1 && anna.holds[0].board === 0, 'a hand over the first artboard is on it, and so is what it holds')
  const next = truth.steps[truth.steps.indexOf(hand) + 1]
  for (const e of next.events) if (e.kind === 'message') bz.liveMessage(e.peer, fromB64(e.plain))
  const then = bz.livePeople().find((p) => p.name === 'Anna')
  check(then?.board === 1 && then.tool === 'text', 'gone to the second artboard and typing, it is there with a text beam')
}
for (const room of truth.pencils) {
  const own = bz.testLive({ pencils: room.replicas })
  check(room.replicas.every((r) => closeAll(own[r], room.colors[r])), `${room.replicas.length} in a room are handed the pencils the Mac hands them`)
}
{
  let worst = 0
  for (const loop of truth.loops) {
    const own = bz.testLive({ loop: loop.seed })
    for (const key of ['points', 'widths']) loop[key].forEach((v, i) => { worst = Math.max(worst, Math.abs(v - (own[key]?.[i] ?? Infinity))) })
  }
  check(worst < 1e-9, `${truth.loops.length} loops are drawn as on the Mac (furthest apart ${worst.toExponential(1)} points)`)
}

// MARK: 2, the page among stand-ins

if (relayURL) {
  console.log(`The page, in a room of ${relayURL}`)
  const relay = new Relay(relayURL)
  const secret = crypto.getRandomValues(new Uint8Array(32))
  const keys = await ShareKeys.fromSecret(secret)
  const owner = b64url(crypto.getRandomValues(new Uint8Array(32)))
  await relay.create(keys.room, { read: await sha256hex(keys.readToken), write: await sha256hex(keys.writeToken), owner: await sha256hex(owner) })
  const writer = new SharedRoom({ keys, relay, me: { replica: 'anna', writer: b64url(crypto.getRandomValues(new Uint8Array(32))), name: 'Anna' } })
  await writer.put(partKey('w', 'anna', 1), fromB64(truth.design))
  await relay.put(keys.room, 'meta', await keys.seal(new TextEncoder().encode(JSON.stringify({ title: 'Live', owner: 'Anna', made: Date.now() })), 'meta'), { write: keys.writeToken, owner })

  /** Someone in the room who says what a Mac said, and hears what is said to it. */
  async function standIn() {
    const ws = new WebSocket(relay.liveURL(keys.room, keys.readToken))
    ws.binaryType = 'arraybuffer'
    const me = { ws, id: 0, came: [], heard: [] }
    let opening = Promise.resolve()
    ws.onmessage = (e) => {
      if (typeof e.data === 'string') return
      const b = new Uint8Array(e.data), view = new DataView(b.buffer)
      if (b[0] === 0x01) me.id = view.getUint32(1)
      else if (b[0] === 0x02) me.came.push(view.getUint32(1))
      else if (b[0] === 0x04) {
        const from = view.getUint32(1), sealed = b.slice(5)
        opening = opening.then(async () => { me.heard.push({ from, plain: await keys.open(sealed, 'live') }) })
      }
    }
    await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = () => fail(new Error(`No relay at ${relayURL}`)) })
    await until(() => me.id !== 0)
    me.say = async (plain) => {
      if (ws.readyState !== 1) return
      const sealed = await keys.seal(plain, 'live'), frame = new Uint8Array(1 + sealed.length)
      frame[0] = 0x10
      frame.set(sealed, 1)
      ws.send(frame)
    }
    // As a Mac does every four seconds, it says again where it is: here every second, for a
    // page that takes three seconds of silence for away.
    const again = setInterval(() => me.last && me.say(me.last), 1000)
    me.hush = () => clearInterval(again)
    me.leave = () => { me.hush(); ws.close() }
    me.settled = () => opening
    return me
  }

  const browser = await launch({ roots: { '/': web }, chrome: arg('chrome') })
  let page
  try {
    // The first Mac is there before the page comes, as in the truth.
    const first = truth.steps[0].events.find((e) => e.kind === 'welcome').others[0]
    const standIns = new Map([[first, await standIn()]])
    page = await browser.open(`/site/shared.html?relay=${encodeURIComponent(relayURL)}&quiet=3&gone=7&still=2000#2.${b64url(secret)}`, { wait: false })
    const opened = await until(() => page.eval('!!window.bezzlePage').catch(() => false), 60000)
    check(!!opened, 'the page opens the design from its link')
    if (!opened) throw new Error('The page did not open: ' + await page.eval('document.getElementById("state").textContent + " / " + document.getElementById("stage").textContent'))
    const watcher = await until(() => standIns.get(first).came[0])
    const began = Date.now()
    const state = async () => JSON.parse(await page.eval('JSON.stringify(window.bezzlePage.live.state)'))
    const tokens = () => page.eval(`[...document.querySelectorAll('.live-people .live-person')].map((e) => ({ label: e.getAttribute('aria-label'), initial: e.firstChild.textContent,
      name: e.querySelector('.live-name span').textContent, color: getComputedStyle(e).backgroundColor, away: e.classList.contains('away'), busy: e.classList.contains('busy') }))`)
    const rgb = (c) => `rgb(${c.map((v) => Math.round(v * 255)).join(', ')})`
    // The colour of the marks at a point of the canvas, `dx`, `dy` of the page's pixels from it.
    const mark = (x, y, dx = 0, dy = 0) => page.eval(`(() => {
      const marks = document.querySelector('canvas.live-marks'), art = document.querySelector('#stage > canvas:not(.film-screen)'), b = window.bezzlePage.shown
      if (!marks || marks.hidden || !art || !b) return null
      const m = marks.getBoundingClientRect(), a = art.getBoundingClientRect(), k = marks.width / m.width, zoom = a.width / b.frame[2]
      const px = Math.floor((a.left - m.left + (${x} - b.frame[0]) * zoom + ${dx}) * k), py = Math.floor((a.top - m.top + (${y} - b.frame[1]) * zoom + ${dy}) * k)
      return [...marks.getContext('2d').getImageData(px, py, 1, 1).data]
    })()`)
    const inked = () => page.eval(`(() => { const c = document.querySelector('canvas.live-marks'); if (!c || c.hidden) return 0
      const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let n = 0; for (let i = 3; i < d.length; i += 4) if (d[i]) n++; return n })()`)
    const isColor = (px, c, by = 6) => !!px && px[3] > 200 && c.every((v, i) => Math.abs(px[i] - Math.round(v * 255)) <= by)
    const shot = async (name) => { if (shots) { await mkdir(shots, { recursive: true }); await writeFile(path.join(shots, `${name}.png`), await page.shot()) } }

    let n = 0
    for (const step of truth.steps) {
      n++
      // The Macs' words, said in this room by their stand-ins.
      for (const e of step.events) {
        if (e.kind === 'joined') standIns.set(e.peer, await standIn())
        else if (e.kind === 'left') { standIns.get(e.peer).leave(); standIns.delete(e.peer) }
        else if (e.kind === 'message') {
          const who = standIns.get(e.peer)
          await who.say(fromB64(e.plain))
          if (e.says === 'presence') who.last = fromB64(e.plain)
        }
      }
      const drawsBefore = await page.eval('window.bezzlePage.draws')
      const settled = await until(async () => {
        const s = await state()
        return s.people.length === step.people.length && step.people.every((mac) => !differs(butAway(mac), s.people.find((p) => p.name === mac.name))) ? s : null
      }, 6000)
      const s = settled ?? await state()
      const off = step.people.map((mac) => [mac.name, differs(butAway(mac), s.people.find((p) => p.name === mac.name))]).filter(([, d]) => d)
      check(!!settled, `${step.name}: the page has ${s.people.length} there, as the Mac` + off.map(([name, d]) => `: ${name}: ${d}`).join(''))
      const shown = await tokens()
      check(shown.length === step.people.length && step.people.every((mac) => shown.some((t) => t.name === mac.name && t.color === rgb(mac.color) && t.initial === (mac.initial ?? mac.name[0]))),
        `  their tokens are in the bar in their pencils: ${shown.map((t) => `${t.initial} ${t.color}${t.busy ? ' at work' : ''}${t.away ? ' away' : ''}`).join(', ') || 'none'}`)
      await shot(`${String(n).padStart(2, '0')}-${step.name.replaceAll(/[^a-z]+/gi, '-')}`)

      if (step.name.startsWith('each holds')) {
        // The outlines of what is held on the artboard shown, in their pencils.
        for (const mac of step.people) {
          const own = s.people.find((p) => p.name === mac.name)
          for (const held of own.holds.filter((h) => h.board === 0)) {
            const [x0, y0, x1, y1] = held.points
            const px = await until(async () => { const got = await mark((x0 + x1) / 2, (y0 + y1) / 2); return got?.[3] ? got : null }, 3000)
            check(!!px && px[3] > 60 && mac.color.every((v, i) => Math.abs(px[i] - Math.round(v * 255)) <= 40), `  what ${mac.name} holds is outlined in their pencil (${px})`)
          }
        }
      }
      if (step.name.startsWith('a hand over the first artboard')) {
        const anna = step.people.find((p) => p.replica === 'anna')
        // Its cross, an arm of it five points above where the pointer is.
        const arm = await until(async () => { const px = await mark(anna.pointer[0], anna.pointer[1], 0, -5); return isColor(px, anna.color) ? px : null }, 4000)
        check(!!arm, `  the hand is over the artboard, a cross in ${anna.name}'s pencil (${arm ?? await mark(anna.pointer[0], anna.pointer[1], 0, -5)})`)
        const theirs = async () => (await state()).hands.find((h) => h.peer === s.people.find((p) => p.name === anna.name).peer)
        const hand = await until(async () => { const h = await theirs(); return h && h.alpha === 1 && closeAll(h.at, anna.pointer, 1e-9) ? h : null }, 3000)
        check(!!hand, `  it has glided to where the Mac's pointer is (${(hand ?? await theirs())?.at}), and shows whole`)
        await shot(`${String(n).padStart(2, '0')}b-hand`)
      }
      if (step.wink) {
        const anna = step.people.find((p) => p.replica === step.wink.replica)
        check((await state()).winks === 1, '  a wink is being drawn')
        // On the second artboard: nothing of it over the first, the one shown.
        const before = await inked()
        const dots = await page.eval(`[...document.querySelectorAll('#boards button')].map((b) => [...b.querySelectorAll('.live-dots i')].map((i) => i.style.background))`)
        check(dots[0]?.length === 0 && dots[1]?.includes(rgb(anna.color)), `  the list of artboards says who is on which (${JSON.stringify(dots)})`)
        // Pressing the token goes there.
        await page.eval(`[...document.querySelectorAll('.live-person')].find((e) => e.querySelector('.live-name span').textContent === ${JSON.stringify(anna.name)}).click()`)
        const went = await until(() => page.eval('window.bezzlePage.shown?.index === 1'), 3000)
        const beam = await until(async () => { const px = await mark(anna.pointer[0], anna.pointer[1], 0, 3); return isColor(px, anna.color) ? px : null }, 4000)
        check(!!went && !!beam, `  pressing ${anna.name}'s token shows the artboard they are on, their hand a text beam there (${beam}; marks before ${before} pixels)`)
        // Typing, their name is beside their hand, in a pill of their pencil.
        const tag = await until(async () => { const px = await mark(anna.pointer[0], anna.pointer[1], 15, 26); return isColor(px, anna.color, 12) ? px : null }, 3000)
        const hand = (await state()).hands.find((h) => h.peer === s.people.find((p) => p.name === anna.name).peer)
        check(!!tag && hand?.tag > 0.9, `  typing, their name is beside their hand (${tag}, shown ${hand?.tag?.toFixed(2)})`)
        const loop = await until(async () => (await inked()) > 600, 2000)
        check(!!loop, '  and the loop they drew round something')
        await shot(`${String(n).padStart(2, '0')}b-wink`)
        await page.eval(`document.querySelector('#boards button').click()`)
      }
      if (step.document) {
        const own = await until(async () => (await page.eval('new TextDecoder().decode(window.bezzlePage.bz.documentBytes())')) === step.document, 5000)
        const draws = await page.eval('window.bezzlePage.draws')
        check(!!own && draws > drawsBefore, `  the change shows as it is made: the page's design is the Mac's, to the byte, drawn again (${draws - drawsBefore} time${draws - drawsBefore === 1 ? '' : 's'})`)
      }
    }

    // The same changes, written to the room's records as the Mac then writes them: taken in, and not drawn again.
    {
      bz.openShared([truth.design], 'watcher')
      const records = []
      for (const stepOf of truth.steps) for (const e of stepOf.events) {
        if (e.kind !== 'message' || e.says !== 'changes') continue
        const r = bz.liveMessage(e.peer, fromB64(e.plain))
        if (r.kind === 'changes') records.push(fromB64(r.record))
      }
      const draws = await page.eval('window.bezzlePage.draws'), seq = await page.eval('window.bezzlePage.room.seq')
      let upTo = 2
      for (const record of records) await writer.put(partKey('c', 'anna', upTo++), record)
      const took = await until(() => page.eval(`window.bezzlePage.room.seq >= ${seq + records.length}`), 8000)
      await sleep(400)
      const after = await page.eval('window.bezzlePage.draws')
      const last = [...truth.steps].reverse().find((s) => s.document).document
      check(!!took && after === draws && (await page.eval('new TextDecoder().decode(window.bezzlePage.bz.documentBytes())')) === last,
        `${records.length} changes come again as the room's records: the design is as it was, and nothing is drawn again (${after - draws} drawings)`)
    }

    // Someone who says nothing more shows as away, and later as gone (here after 3 and 7 seconds).
    {
      for (const who of standIns.values()) who.hush()
      const quiet = await until(async () => { const t = await tokens(); return t.length === 1 && t[0].away ? t : null }, 6000)
      check(!!quiet, 'someone silent a while shows as away')
      const gone = await until(async () => (await tokens()).length === 0, 8000)
      check(!!gone && (await inked()) === 0, 'and much later as gone, with nothing of them left over the artboard')
      const anna = [...standIns.values()][0], hello = truth.steps[0].events.find((e) => e.says === 'hello')
      await anna.say(fromB64(hello.plain))
      check(!!(await until(async () => { const t = await tokens(); return t.length === 1 && !t[0].away }, 3000)), 'heard again, they are back')
    }

    // The page said nothing in the room but that it is still there.
    {
      await sleep(2600)
      const anna = [...standIns.values()][0]
      await anna.settled()
      const fromPage = anna.heard.filter((h) => h.from === watcher)
      const still = Buffer.from(STILL_THERE)
      check(fromPage.length >= 2 && fromPage.every((h) => h.plain && Buffer.compare(Buffer.from(h.plain), still) === 0) && anna.heard.length === fromPage.length + anna.heard.filter((h) => h.from !== watcher).length,
        `the page said nothing but that it is still there (${fromPage.length} times in ${Math.round((Date.now() - began) / 1000)} s, every 2 s for this test), never who it is`)
      // Not while nobody looks at it.
      await page.eval(`Object.defineProperty(document, 'hidden', { get: () => true })`)
      await sleep(300)
      const before = anna.heard.length
      await sleep(4500)
      await anna.settled()
      check(anna.heard.length === before, 'and nothing at all while its tab is hidden')
    }
    for (const s of standIns.values()) s.leave()
    check(!!(await until(async () => (await state()).people.length === 0, 4000)), 'everyone gone, nobody is shown')
  } finally {
    await browser.close()
    // The room is taken down again.
    await fetch(`${relay.base}/v2/${keys.room}`, { method: 'DELETE', headers: { Authorization: `Bearer ${keys.writeToken}`, 'X-Bezzle-Owner': owner } }).catch(() => {})
  }
}

console.log(failed ? `${failed} of ${checked} failed` : `all ${checked} passed`)
process.exit(failed ? 1 : 0)
