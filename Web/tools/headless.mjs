// A headless Chromium of the tools' own (Playwright's, from ~/Library/Caches/ms-playwright, or one
// named), with a page served from this Mac alone, for what Node cannot show: WebGL, a real page.
// Never the browser someone works in. Talks to it over its DevTools socket, without Playwright.
//
//   const browser = await launch({ roots: { '/site/': dir, … }, files: { '/core.wasm': path }, pages: { '/harness.html': html } })
//   const page = await browser.open('/harness.html')        // waits for window.ready, fails on window.failed
//   const value = await page.eval('expression')             // awaited, returned by value
//   const value = await page.call('fn', ...args)            // window.harness.fn(...args)
//   await browser.close()

import { readFile, readdir, mkdir, mkdtemp, rm, stat } from 'node:fs/promises'
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { tmpdir, homedir } from 'node:os'
import path from 'node:path'

const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.gz': 'application/gzip', '.deflate': 'application/octet-stream' }

export async function findChrome(named) {
  if (named) return named
  const cache = path.join(homedir(), 'Library/Caches/ms-playwright')
  for (const dir of (await readdir(cache).catch(() => [])).filter((d) => d.startsWith('chromium_headless_shell-')).sort().reverse()) {
    for (const sub of await readdir(path.join(cache, dir)).catch(() => [])) {
      const bin = path.join(cache, dir, sub, 'chrome-headless-shell')
      if (await stat(bin).then((s) => s.isFile(), () => false)) return bin
    }
  }
  throw new Error('No headless Chromium found: give one with --chrome <path>.')
}

/**
 * `roots`: URL prefix → folder served under it. `files`: URL → one file. `pages`: URL → HTML given
 * here. `chrome`: a browser's path instead of Playwright's. `profile`: a folder to keep its
 * profile in (one of its own, thrown away, otherwise). `log`: where the page's errors go.
 */
export async function launch({ roots = {}, files = {}, pages = {}, chrome, profile, flags = [], log = (line) => console.log('[page]', line) } = {}) {
  const server = createServer(async (req, res) => {
    try {
      const url = decodeURIComponent(new URL(req.url, 'http://x').pathname)
      if (pages[url] !== undefined) { res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' }); return res.end(pages[url]) }
      let file = files[url] ?? null
      for (const [prefix, root] of Object.entries(roots)) {
        if (!file && url.startsWith(prefix)) file = path.join(root, path.normalize(url.slice(prefix.length)).replace(/^(\.\.[/\\])+/, ''))
      }
      if (!file || !(await stat(file)).isFile()) throw new Error('none')
      res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' })
      res.end(await readFile(file))
    } catch { res.writeHead(404); res.end() }
  })
  await new Promise((ok) => server.listen(0, '127.0.0.1', ok))
  const origin = `http://127.0.0.1:${server.address().port}`

  const own = !profile
  const folder = profile ?? await mkdtemp(path.join(tmpdir(), 'bezzle-headless-'))
  await mkdir(folder, { recursive: true })
  const process = spawn(await findChrome(chrome), ['--remote-debugging-port=0', `--user-data-dir=${folder}`, '--no-first-run', '--no-default-browser-check',
    '--enable-gpu', '--use-angle=metal', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader', '--window-size=1400,1000', ...flags, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] })
  let closed = false
  const close = async () => {
    if (closed) return
    closed = true
    process.kill()
    server.close()
    if (own) await rm(folder, { recursive: true, force: true }).catch(() => {})
  }
  let wsUrl
  try {
    wsUrl = await new Promise((ok, fail) => {
      let said = ''
      process.stderr.on('data', (d) => { said += d; const m = said.match(/DevTools listening on (ws:\/\/\S+)/); if (m) ok(m[1]) })
      process.on('exit', () => fail(new Error('Chromium did not start: ' + said.slice(0, 600))))
      setTimeout(() => fail(new Error('Chromium did not answer in time')), 30000)
    })
  } catch (e) { await close(); throw e }

  const ws = new WebSocket(wsUrl)
  await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail })
  let nextId = 1
  const waiting = new Map()
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data)
    if (m.id && waiting.has(m.id)) { const w = waiting.get(m.id); waiting.delete(m.id); m.error ? w.fail(new Error(m.error.message)) : w.ok(m.result) }
    else if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type)) log(m.params.args.map((a) => a.value ?? a.description ?? '').join(' ').slice(0, 400))
    else if (m.method === 'Runtime.exceptionThrown') log((m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text).slice(0, 600))
  }
  const send = (method, params = {}, sessionId) => new Promise((ok, fail) => { const id = nextId++; waiting.set(id, { ok, fail }); ws.send(JSON.stringify({ id, method, params, sessionId })) })

  /** A tab at `url` (a path served here, or a whole address). With `wait`, until window.ready is set. */
  async function open(url, { wait = true, patience = 120000 } = {}) {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
    await send('Runtime.enable', {}, sessionId)
    await send('Page.enable', {}, sessionId)
    const evaluate = async (expression) => {
      const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId)
      if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text)
      return r.result.value
    }
    await send('Page.navigate', { url: url.startsWith('/') ? origin + url : url }, sessionId)
    if (wait) {
      const began = Date.now()
      for (;;) {
        const state = await evaluate('window.ready ? "ready" : window.failed ?? ""').catch(() => '')
        if (state === 'ready') break
        if (state || Date.now() - began > patience) throw new Error('The page did not start: ' + (state || 'no answer'))
        await new Promise((ok) => setTimeout(ok, 200))
      }
    }
    return {
      eval: evaluate,
      call: (fn, ...args) => evaluate(`window.harness.${fn}(${args.map((a) => JSON.stringify(a)).join(',')})`),
      /** A picture of the tab as it shows, PNG bytes. */
      async shot() { return Buffer.from((await send('Page.captureScreenshot', { format: 'png' }, sessionId)).data, 'base64') },
      /** The tab's memory as the browser counts it: its JavaScript heap, in bytes. */
      async heap() { await send('HeapProfiler.collectGarbage', {}, sessionId); return (await send('Runtime.getHeapUsage', {}, sessionId)).usedSize },
      close: () => send('Target.closeTarget', { targetId }),
    }
  }

  return { origin, open, close }
}
