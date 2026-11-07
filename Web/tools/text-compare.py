"""Compares Text Kit's measures on the Mac (TextMeasureTests.swift) with the Windows core's
(bezzle-render with BEZZLE_TEXTS, one file per design in a folder): the sample designs' texts
(lines, baselines, sizes, frames after a refit), the probes (one line, three lines, lines set
apart, mixed sizes and families, tracked, empty, paragraphs set apart, breaks at either end, a
fine sweep of sizes) and the widths of words in every face. With an ink file of each side
(BEZZLE_INK, TextMeasureTests' ink-mac.json), where letters are drawn against their baselines.

  python3 -I tools/text-compare.py <text-measure-mac.json> <windows folder> [--detail]
      [--ink <ink-mac.json> <windows ink.json>]
"""
import json, sys, os, statistics as st
from collections import defaultdict

mac = json.load(open(sys.argv[1]))
win = {'samples': [], 'probes': [], 'extra': {}}
for f in sorted(os.listdir(sys.argv[2])):
    if f.endswith('.json') and f != 'ink.json':
        r = json.load(open(os.path.join(sys.argv[2], f)))
        win['samples'] += r['samples']
        win['probes'] += r['probes']
        win['extra'].update(r.get('extra', {}))
detail = '--detail' in sys.argv
W = {p['key']: p for p in win['samples'] + win['probes']}


def summary(xs):
    if not xs:
        return 'none'
    return f"mean |d| {st.mean(abs(x) for x in xs):.2f}, max |d| {max(abs(x) for x in xs):.2f}, mean d {st.mean(xs):+.2f}"


def breaks(l):
    return [x[:2] for x in l['lines']]


print('== Sample texts ==')
rows = [(m, W[m['key']]) for m in mac['samples'] if m['key'] in W]
print(f"{len(rows)} texts; lines broken alike {sum(breaks(m) == breaks(w) for m, w in rows)}")
for name, f in [
    ('first baseline', lambda m, w: w['firstBaseline'] - m['firstBaseline']),
    ('first line height', lambda m, w: w['lines'][0][3] - m['lines'][0][3] if m['lines'] and w['lines'] else None),
    ('height, lines broken alike', lambda m, w: w['used'][1] - m['used'][1] if breaks(m) == breaks(w) else None),
    ('height', lambda m, w: w['used'][1] - m['used'][1]),
    ('natural line height', lambda m, w: w['naturalLineHeight'] - m['naturalLineHeight']),
    ('natural width (pt)', lambda m, w: w['natural'] - m['natural']),
    ('natural width (%)', lambda m, w: 100 * (w['natural'] - m['natural']) / m['natural'] if m['natural'] else None),
]:
    v = [x for x in (f(m, w) for m, w in rows) if x is not None]
    print(f"  {name:28} {sum(abs(x) < 0.01 for x in v)}/{len(v)} equal; {summary(v)}")
by = defaultdict(list)
for m, w in rows:
    by[m['sizing']].append((m, w))
for sizing, rs in sorted(by.items()):
    same = [(m, w) for m, w in rs if all(abs(a - b) < 0.01 for a, b in zip(m['refit'], w['refit']))]
    print(f"  refit {sizing:10} {len(same)}/{len(rs)} frames equal; width {summary([w['refit'][2] - m['refit'][2] for m, w in rs])}; "
          f"height {summary([w['refit'][3] - m['refit'][3] for m, w in rs])}")
    if detail:
        for m, w in rs:
            if (m, w) not in same:
                print(f"      {m['design']:20} {m['family']} {m['face']} {m['size']} {m['text'][:30]!r}: mac {[round(v, 1) for v in m['refit']]}, "
                      f"windows {[round(v, 1) for v in w['refit']]}")

decks = {}
for f in sorted(os.listdir(sys.argv[2])):
    if f.endswith('.json') and f != 'ink.json':
        decks.update(json.load(open(os.path.join(sys.argv[2], f))).get('decks', {}))
if mac.get('decks') and decks:
    # Posts are numbered at random when made, so only how many seem broken is compared.
    print('== Each artboard made a deck of two posts: how many seem broken, texts as kept | refitted ==')
    alike = 0
    for design, boards in sorted(mac['decks'].items()):
        for board, (kept, refit) in sorted(boards.items()):
            w = decks.get(design, {}).get(board)
            if w is None:
                continue
            same = [len(kept), len(refit)] == [len(w[0]), len(w[1])]
            alike += same
            print(f"  {design + ' / ' + board:40} mac {len(kept)} | {len(refit)}   windows {len(w[0])} | {len(w[1])}   {'alike' if same else 'DIFFER'}")
    print(f"  {alike} alike")

print('== Probes ==')
P = [(p, W[p['key']]) for p in mac['probes'] if p['key'] in W]
for kind in ['one', 'three', 'spaced', 'mixed', 'tracked', 'words']:
    ps = [(m, w) for m, w in P if m['key'].startswith(kind + '/')]
    alike = sum(len(m['lines']) == len(w['lines']) and all(max(abs(b[2] - a[2]), abs(b[3] - a[3]), abs(b[5] - a[5])) < 0.01
                for a, b in zip(m['lines'], w['lines'])) for m, w in ps)
    print(f"  {kind:8} lines placed alike {alike}/{len(ps)}; baselines {summary([w['lines'][0][5] - m['lines'][0][5] for m, w in ps])}")
kinds = defaultdict(lambda: [0, 0])
for k, m in mac.get('extra', {}).items():
    w = win['extra'].get(k)
    if k == 'units' or k.startswith('corpus/') or w is None:
        continue
    kind = k.split('/')[0]
    if kind == 'fine':
        ok = abs(m[0] - w[0]) < 0.01 and abs(m[1] - w[1]) < 0.01
    else:
        # Skia lists the empty line after a final break, which Text Kit keeps as its extra line
        # fragment rather than a line; both count it in the height.
        wl = w['lines'][:-1] if len(w['lines']) == len(m['lines']) + 1 and w['lines'][-1][4] == 0 else w['lines']
        ok = len(m['lines']) == len(wl) and all(max(abs(a[2] - b[2]), abs(a[3] - b[3]), abs(a[5] - b[5])) < 0.01 for a, b in zip(m['lines'], wl))
        ok = ok and abs(m['used'][1] - w['used'][1]) < 0.01 and abs(m['firstBaseline'] - w['firstBaseline']) < 0.01
    kinds[kind][0] += ok
    kinds[kind][1] += 1
for kind, (good, n) in sorted(kinds.items()):
    print(f"  {kind:10} alike {good}/{n}")

print('== Widths of words, Windows against the Mac ==')
CORPUS = len({k.split('/')[1] for k in mac.get('extra', {}) if k.startswith('corpus/')})
faces = defaultdict(list)
for k, m in mac.get('extra', {}).items():
    if k.startswith('corpus/') and k in win['extra']:
        _, i, fam, face, size = k.split('/')
        faces[f"{fam} {face}"].append(100 * (win['extra'][k][0] - m[0]) / m[0])
for face, v in sorted(faces.items()):
    print(f"  {face:34} mean |d| {st.mean(abs(x) for x in v):5.2f}%  mean d {st.mean(v):+6.2f}%  max |d| {max(abs(x) for x in v):5.2f}%")

if '--ink' in sys.argv:
    i = sys.argv.index('--ink')
    mi, wi = json.load(open(sys.argv[i + 1])), json.load(open(sys.argv[i + 2]))
    print('== Where letters are drawn (bottom of "HHHH" against the Mac\'s, pt) ==')
    fams = defaultdict(list)
    for k, m in mi.items():
        if k in wi:
            fams[k.split('/')[0]].append(wi[k][2] - m[2])
    for fam, v in sorted(fams.items()):
        print(f"  {fam:16} {summary(v)}")
