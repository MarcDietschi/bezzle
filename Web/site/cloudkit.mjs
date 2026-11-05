// iCloud for a design shared with someone in a browser, through CloudKit Web Services: the person
// signs in with their Apple ID, accepts the share by its invitation code, and reads and writes
// the zone's records as Bezzle on a Mac does (see CloudSync.swift). Written to Apple's CloudKit
// Web Services Reference; not yet run against iCloud.
//
// Still to find out against iCloud, which the reference (2016) does not say: whether records/accept
// takes a zone-wide share's code (Bezzle shares whole zones), and whether assets can be uploaded
// into another person's zone (the reference names only the public and private databases), which
// large changes and pictures need. Every call answers what iCloud said, so the page can show it.

const base = 'https://api.apple-cloudkit.com/database/1'

export class CloudKit {
  /** `apiToken` is made in the CloudKit Console (API Access › API Tokens); it is not a secret. */
  constructor({ container = 'iCloud.com.erik.Bezzle', environment = 'production', apiToken }) {
    this.container = container
    this.environment = environment
    this.apiToken = apiToken
    this.webAuthToken = safe(() => sessionStorage.getItem('bezzle.ckWebAuthToken')) ?? null
  }

  url(database, path) {
    const q = new URLSearchParams({ ckAPIToken: this.apiToken })
    if (this.webAuthToken) q.set('ckWebAuthToken', this.webAuthToken)
    return `${base}/${this.container}/${this.environment}/${database}/${path}?${q}`
  }

  /** One request; answers { ok, status, body }. A sign-in needed answers { signIn: redirectURL }. */
  async call(database, path, body, method = 'POST') {
    const response = await fetch(this.url(database, path), {
      method, headers: body ? { 'Content-Type': 'text/plain' } : undefined, body: body ? JSON.stringify(body) : undefined,
    })
    const text = await response.text()
    let json = null
    try { json = JSON.parse(text) } catch {}
    // A token is good for one round trip; the next comes with the answer.
    const next = json?.ckWebAuthToken ?? response.headers.get('X-Apple-CloudKit-Web-Auth-Token')
    if (next) this.keep(next)
    if (response.status === 421 || json?.serverErrorCode === 'AUTHENTICATION_REQUIRED') return { signIn: json?.redirectURL, status: response.status, body: json }
    return { ok: response.ok, status: response.status, body: json ?? text }
  }

  keep(token) {
    this.webAuthToken = token
    safe(() => sessionStorage.setItem('bezzle.ckWebAuthToken', token))
  }

  /** Opens Apple's sign-in, and waits for the token it posts back to this page. */
  signIn(redirectURL) {
    return new Promise((resolve, reject) => {
      const window_ = window.open(redirectURL, 'bezzle-sign-in', 'width=560,height=720')
      if (!window_) return reject(new Error('The sign-in window was blocked.'))
      const heard = (e) => {
        const token = e.data?.ckWebAuthToken
        if (!token) return
        window.removeEventListener('message', heard)
        this.keep(token)
        resolve(token)
      }
      window.addEventListener('message', heard)
    })
  }

  /** Whether someone is signed in: their own zones, or a sign-in needed. (users/current and
   *  users/caller answered AUTHENTICATION_FAILED before anyone signed in, rather than asking.) */
  me() { return this.call('private', 'zones/list', null, 'GET') }

  /** Accepts the share whose invitation code this is: its zone, and who owns it. */
  accept(code) {
    return this.call('public', 'records/accept', { shortGUIDs: [{ value: code, shouldFetchRootRecord: false }] })
  }

  /** Every record of a zone, or those since `syncToken`: in `database` "shared" for a design
   *  shared with the person, "private" for one of their own. */
  async records(zoneID, syncToken, database = 'shared') {
    const out = []
    let token = syncToken
    for (;;) {
      const zone = { zoneID }
      if (token) zone.syncToken = token
      const r = await this.call(database, 'changes/zone', { zones: [zone] })
      const z = r.body?.zones?.[0]
      if (!r.ok || !z || z.serverErrorCode) return { ...r, records: out, syncToken: token }
      out.push(...(z.records ?? []))
      token = z.syncToken
      if (!z.moreComing) return { ok: true, records: out, syncToken: token }
    }
  }

  /** A record's packed design: its bytes field, or its file. */
  async packed(record) {
    const f = record.fields ?? {}
    if (f.data?.value) return f.data.value
    const url = f.file?.value?.downloadURL
    if (!url) return null
    const bytes = new Uint8Array(await (await fetch(url.replace('${f}', 'file'))).arrayBuffer())
    let s = ''
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    return btoa(s)
  }

  /** A picture record's name and bytes. */
  async picture(record) {
    const name = record.fields?.name?.value, url = record.fields?.file?.value?.downloadURL
    if (!name || !url) return null
    return [name, new Uint8Array(await (await fetch(url.replace('${f}', encodeURIComponent(name)))).arrayBuffer())]
  }

  /** Sends this browser's changes as a change record of its own, as a Mac sends its own. */
  sendChange(zoneID, { data, upTo }, replica, database = 'shared') {
    return this.call(database, 'records/modify', {
      zoneID,
      operations: [{
        operationType: 'create',
        record: {
          recordType: 'Change', recordName: `change-${crypto.randomUUID().toUpperCase()}`,
          fields: { by: { value: replica, type: 'STRING' }, upTo: { value: upTo, type: 'INT64' }, data: { value: data, type: 'BYTES' } },
        },
      }],
    })
  }
}

function safe(f) { try { return f() } catch { return undefined } }
