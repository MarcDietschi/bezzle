"""Compares lists as Text Kit sets them on the Mac (ListTruthTests.swift's lists-mac.json) with
the Windows core's (bezzle-render with BEZZLE_TEXTS and BEZZLE_TEXTS_PROBES=0 on the same
Lists.bezzle): for each text, its lines (where they break, their tops and baselines, where their
letters begin), its size and natural width, and each marker's text and place.

  python3 -I tools/list-compare.py <lists-mac.json> <lists-win.json> [--detail]
"""
import json, sys

mac = {s['key']: s for s in json.load(open(sys.argv[1]))['samples']}
win = {s['key']: s for s in json.load(open(sys.argv[2]))['samples']}
detail = '--detail' in sys.argv


def worst(pairs):
    return max((abs(a - b) for a, b in pairs), default=0)


rows = []
for key, m in mac.items():
    w = win.get(key)
    if not w:
        print(f"missing on Windows: {key}")
        continue
    # Skia lists the empty line after a final break, which Text Kit keeps as its extra fragment.
    wl = w['lines'][:-1] if len(w['lines']) == len(m['lines']) + 1 and w['lines'][-1][4] == 0 else w['lines']
    broken = [l[:2] for l in m['lines']] == [l[:2] for l in wl]
    lines = len(m['lines']) == len(wl)
    tops = worst((a[2], b[2]) for a, b in zip(m['lines'], wl)) if lines else None
    bases = worst((a[5], b[5]) for a, b in zip(m['lines'], wl)) if lines else None
    lefts = worst((a[7], b[7]) for a, b in zip(m['lines'], wl)) if lines else None
    texts = [x[0] for x in m['markers']] == [x[0] for x in w['markers']]
    mx = worst((a[1], b[1]) for a, b in zip(m['markers'], w['markers'])) if texts else None
    my = worst((a[2], b[2]) for a, b in zip(m['markers'], w['markers'])) if texts else None
    rows.append((key, m, w, broken, tops, bases, lefts, texts, mx, my))
    print(f"{m['board']:8} {m['text'][:24]!r:28} breaks {'alike' if broken else 'DIFFER'}  "
          f"tops {tops if tops is None else round(tops, 2)}  baselines {bases if bases is None else round(bases, 2)}  "
          f"line starts {lefts if lefts is None else round(lefts, 2)}  markers {'alike' if texts else 'DIFFER'} "
          f"x {mx if mx is None else round(mx, 2)} y {my if my is None else round(my, 2)}  "
          f"used {[round(v, 1) for v in m['used']]} | {[round(v, 1) for v in w['used']]}  natural {m['natural']} | {w['natural']}")
    if detail and (not broken or not texts):
        print('    mac', [l[:2] for l in m['lines']], [x[:3] for x in m['markers']])
        print('    win', [l[:2] for l in wl], [x[:3] for x in w['markers']])
print(f"{sum(r[3] for r in rows)}/{len(rows)} broken alike, {sum(r[7] for r in rows)}/{len(rows)} markers alike")
