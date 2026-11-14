// Holds the page's words (site/words.mjs) to the app's and the website's own:
//  - every language has every word, written as Bezzle writes: no dashes as punctuation, no
//    exclamation marks, German's dots after a space and French's and Italian's without one;
//  - where the app says the same thing, the page says it in the app's words
//    (Bezzle/Localizable.xcstrings), with "tu" where the app's French says "vous";
//  - with --site <bezzle-web>, an incomplete link is answered as the website's invitation page
//    answers it (its src/words.js).
//
//   node tools/words.mjs [--site ~/Sites/bezzle-web]

import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { WORDS, language } from '../site/words.mjs'

const here = path.dirname(new URL(import.meta.url).pathname)
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback }
const app = JSON.parse(await readFile(path.join(here, '..', '..', 'Bezzle', 'Localizable.xcstrings'), 'utf8')).strings
const site = arg('site')

let failed = 0, checked = 0
const check = (ok, what) => { checked++; if (!ok) { failed++; console.log(`  FAIL ${what}`) } }
const langs = Object.keys(WORDS)
/** A word as text: a sentence in two halves joined, a word with a name in it given "%@". */
const text = (v) => (typeof v === 'function' ? v('%@') : Array.isArray(v) ? v.join(' ') : v)
/** The app's own word for `key` in a language; its key is its English. */
const appSays = (key, lang) => (lang === 'en' ? key : app[key]?.localizations?.[lang]?.stringUnit?.value)
// A space that does not break is a space here.
const plain = (s) => s?.replaceAll(' ', ' ').replaceAll(' ', ' ')

// Every language has every word, and each is written as Bezzle writes.
const keys = Object.keys(WORDS.en)
for (const lang of langs) {
  check(keys.every((k) => k in WORDS[lang]) && Object.keys(WORDS[lang]).length === keys.length, `${lang} has every word`)
  for (const k of keys) {
    const said = text(WORDS[lang][k])
    check(!/[—!]|\s[–-]\s/.test(said), `${lang} ${k}: no dash as punctuation, no exclamation mark: ${said}`)
    if (said.includes('…')) check(lang === 'de' ? / …/.test(said) : !/\s…/.test(said), `${lang} ${k}: the dots as ${lang} sets them: ${said}`)
    check(!said.includes("'") && !said.includes('...'), `${lang} ${k}: a curled apostrophe and one sign for the dots: ${said}`)
  }
}

// The app's own words, where it has them. Its French says "vous": the page's "tu" is made from it.
const tu = (s) => s.replace('Vérifiez', 'Vérifie').replace('ouvrez', 'ouvre')
const same = [
  ['gone', 'No longer shared'],
  ['by', 'Shared by %@'],
  ['ended', 'This design is no longer shared. The design’s owner has stopped sharing it.', ['This design is no longer shared.', 'The design’s owner has stopped sharing it.']],
  ['unreachable', 'Bezzle could not reach the design. Check the connection and open the link again.'],
  ['goTo', 'Go to %@'],
  ['film', 'Film'],
  ['boards', 'Artboards'],
  ['people', 'People…', null, (s) => s.replace(/\s*…$/, '')],
]
for (const [word, key, parts, trim = (s) => s] of same) {
  for (const lang of langs) {
    const theirs = parts ? parts.map((p) => appSays(p, lang)).join(' ') : appSays(key, lang)
    const own = text(WORDS[lang][word])
    check(!!theirs && plain(own) === plain(trim(lang === 'fr' ? tu(theirs) : theirs)), `${lang} ${word}: “${own}”, the app says “${theirs}”`)
  }
}
for (const lang of langs) {
  check(plain(WORDS[lang].missing[0]) === plain(appSays('This link does not lead to a design.', lang)), `${lang} missing: “${WORDS[lang].missing[0]}”, the app says “${appSays('This link does not lead to a design.', lang)}”`)
  // An artboard by the app's name for it, one or several.
  const names = ['Artboard', 'Artboards'].map((k) => appSays(k, lang)?.toLowerCase())
  check(names.some((n) => n && WORDS[lang].empty[1].toLowerCase().includes(n)), `${lang} empty: an artboard is called ${names.join(' or ')}: ${WORDS[lang].empty[1]}`)
}

// The website's invitation page, for a link that is not whole.
if (site) {
  const theirs = [...(await readFile(path.join(site, 'src', 'words.js'), 'utf8')).matchAll(/"inv_missing":\s*"([^"]+)"/g)].map((m) => m[1])
  check(theirs.length === langs.length, `the website has ${theirs.length} sentences for an incomplete link`)
  for (const lang of langs) {
    const own = WORDS[lang].incomplete.join(' ')
    check(theirs.includes(own), `${lang} incomplete: “${own}” is not among the website's: ${theirs.join(' | ')}`)
    check(WORDS[lang].missing[1] === WORDS[lang].incomplete[1], `${lang} missing asks as incomplete does`)
  }
}

// The visitor's language: the first the page has, whatever its region; English otherwise.
check(language(['de-CH', 'en']) === 'de' && language(['pt-BR', 'it']) === 'it' && language(['ja']) === 'en' && language(['FR']) === 'fr', 'the first of the visitor’s languages the page has is taken')

console.log(failed ? `${failed} of ${checked} failed` : `all ${checked} passed: ${keys.length} words in ${langs.join(', ')}${site ? ', with the website' : ''}`)
process.exit(failed ? 1 : 0)
