// Tests editing in the browser's core, on a sample design, as two copies of a shared design:
// moves, resizing and retyping a text, colours, deleting, a drag as one step, notes, and undo that
// takes back only what was done here, leaving what the other copy changed meanwhile.
//
//   node tools/edit.mjs [--wasm <core>]

import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
import { createBezzle } from '../site/bezzle.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const require = createRequire(import.meta.url)
const CK = await require('canvaskit-wasm/bin/canvaskit.js')({ locateFile: (f) => require.resolve(`canvaskit-wasm/bin/${f}`) })
const fontsDir = path.join(here, '..', 'site', 'fonts')
const manifest = JSON.parse(await readFile(path.join(fontsDir, 'manifest.json'), 'utf8'))
const fonts = {
  families: manifest.families,
  faces: await Promise.all(manifest.faces.map(async (f) => ({ ...f, data: await readFile(path.join(fontsDir, f.file)) }))),
  system: { ...manifest.system, data: await readFile(path.join(fontsDir, manifest.system.file)) },
}
const wasm = await readFile(arg('wasm', path.join(here, '..', '.build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm')))
const core = () => createBezzle({ CanvasKit: CK, wasm, fonts, options: { trak: true } })

let failed = 0
const check = (ok, what) => { console.log(`${ok ? '  ok ' : '  FAIL'} ${what}`); if (!ok) failed++ }
const near = (a, b) => Math.abs(a - b) < 1e-6

const pkg = path.join(here, '..', '..', 'AppStore', 'screenshots-src', 'designs', 'Wander.bezzle')
const a = await core(), b = await core()
a.open(await readFile(path.join(pkg, 'document.json')))
const first = a.snapshot().data
const opened = a.openShared([first], 'anna')
b.openShared([first], 'ben')
const board = opened.boards[0].index
const layers = a.layers(board)
const find = (copy, pred) => copy.layers(board).find(pred)
check(layers.length > 10 && layers.every((l) => l.frame.length === 4), `the artboard's layers come with frames (${layers.length})`)

// A move.
const rect = layers.find((l) => l.depth === 0 && !l.container && l.kind !== 'text')
const moved = a.edit([{ op: 'move', ids: [rect.id], dx: 12, dy: -3 }])
const after = find(a, (l) => l.id === rect.id)
check(near(after.frame[0], rect.frame[0] + 12) && near(after.frame[1], rect.frame[1] - 3) && moved.undo, 'a layer moves, as one step to undo')

// A drag is one step, however many moves: each measured from where it began.
a.begin()
for (let i = 1; i <= 10; i++) a.edit([{ op: 'move', ids: [rect.id], dx: i, dy: 0 }])
a.end()
check(near(find(a, (l) => l.id === rect.id).frame[0], after.frame[0] + 10), 'a drag of ten moves ends where the last one put it')
a.undo()
check(near(find(a, (l) => l.id === rect.id).frame[0], after.frame[0]), 'and one undo takes the whole drag back')

// Text: new words, and a wider frame that the words wrap in.
const text = layers.find((l) => l.kind === 'text' && l.text.length > 3)
a.edit([{ op: 'text', id: text.id, text: 'Words typed in a browser' }])
const typed = find(a, (l) => l.id === text.id)
check(typed.text === 'Words typed in a browser' && typed.frame[2] !== text.frame[2], 'a text takes new words and fits them')
a.edit([{ op: 'frame', id: text.id, frame: [typed.frame[0], typed.frame[1], 80, typed.frame[3]] }])
const wrapped = find(a, (l) => l.id === text.id)
check(wrapped.style.sizing === 'autoHeight' && wrapped.frame[2] === 80 && wrapped.frame[3] > typed.frame[3], 'made narrower, it wraps there and grows taller')

// Colour, border, type, opacity, corners.
a.edit([{ op: 'fill', ids: [rect.id], color: [1, 0, 0, 1] }, { op: 'border', ids: [rect.id], on: true, color: [0, 0, 1, 1], width: 3 },
  { op: 'opacity', ids: [rect.id], value: 0.5 }, { op: 'radius', ids: [rect.id], value: 9 }])
const painted = find(a, (l) => l.id === rect.id)
check(painted.fill[0] === 1 && painted.fill[1] === 0 && painted.border.on && painted.border.width === 3 && painted.opacity === 0.5 && painted.radius === 9,
  'fill, border, opacity and corners change')
a.edit([{ op: 'font', ids: [text.id], size: 30, align: 'center' }])
check(find(a, (l) => l.id === text.id).style.size === 30 && find(a, (l) => l.id === text.id).style.align === 'center', 'type size and alignment change')

// The other copy changes something else; undo here leaves it.
const other = layers.filter((l) => l.depth === 0 && l.id !== rect.id && l.id !== text.id && !l.container)[0]
b.edit([{ op: 'move', ids: [other.id], dx: 40, dy: 0 }])
a.receive([b.changes().data])
check(near(find(a, (l) => l.id === other.id).frame[0], other.frame[0] + 40), 'the other copy’s change comes in')
a.undo() // the type
a.undo() // the colours
check(find(a, (l) => l.id === rect.id).fill[0] !== 1 && near(find(a, (l) => l.id === other.id).frame[0], other.frame[0] + 40),
  'undo takes back only what was done here: the other copy’s change stays')
a.redo()
check(find(a, (l) => l.id === rect.id).fill[0] === 1, 'and redo brings it back')

// Deleting.
a.edit([{ op: 'delete', ids: [other.id] }])
check(!find(a, (l) => l.id === other.id), 'a layer can be deleted')
a.undo()
check(!!find(a, (l) => l.id === other.id), 'and comes back with undo')

// Notes: a thread on a layer, an answer from the other copy, ticked off.
a.edit([{ op: 'note', ids: [rect.id], text: 'Is this the right red?', by: 'Anna', replica: 'anna' }])
b.receive([a.changes().data])
const thread = b.notes().find((n) => n.text === 'Is this the right red?')
check(thread && thread.on === rect.id && thread.by === 'Anna', 'a note on a layer reaches the other copy')
b.edit([{ op: 'answer', thread: thread.id, text: 'A little warmer, please', by: 'Ben', replica: 'ben' }])
a.receive([b.changes().data])
const answered = a.notes().find((n) => n.id === thread.id)
check(answered.answers.length === 1 && answered.answers[0].by === 'Ben', 'its answer comes back')
a.edit([{ op: 'done', thread: thread.id, done: true }])
check(a.notes().find((n) => n.id === thread.id).done, 'and the thread can be ticked off')

// Both copies end with the same design.
b.receive([a.changes().data].filter(Boolean))
a.receive([b.changes().data].filter(Boolean))
check(JSON.stringify(a.document().nodes) === JSON.stringify(b.document().nodes), 'both copies end with the same design')
check(a.render(board, 1).image.width() > 0, 'and it draws')

console.log(failed ? `${failed} failed` : 'all passed')
process.exit(failed ? 1 : 0)
