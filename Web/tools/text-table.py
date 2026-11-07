"""Makes the tables of Web/Sources/BezzleCore/Web/MacFonts.swift again from the measures: each Mac
face's ascent, descent and leading and whether Text Kit gives it a fifth more room above
(TextMeasureTests.swift on the Mac), and the letter spacing that makes each stand-in as wide as
its face, fitted on the widths of words (the `corpus` probes) with the stand-ins unspaced
(bezzle-render with BEZZLE_TEXTS and BEZZLE_TEXTS_PLAIN=1).

  python3 -I tools/text-table.py <text-measure-mac.json> <windows folder, unspaced> > tables.swift

The spacing is ten-thousandths of an em a letter: by size for the system font (SF Pro is tracked
by size, Inter is not), at the sizes MacFonts.systemSizes lists, held to 0.04 em; once a face for
the others, held to 0.03 em, and left out under 0.001 em.
"""
import json, sys, os, math

mac = json.load(open(sys.argv[1]))['extra']
win = {}
for f in os.listdir(sys.argv[2]):
    if f.endswith('.json') and f != 'ink.json':
        win.update(json.load(open(os.path.join(sys.argv[2], f))).get('extra', {}))
units = mac['units']
SIZES = [9, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 28, 32, 40, 48, 64, 72, 96, 132]
CORPUS = [
    "The quick brown fox jumps over the lazy dog.", "Pack my box with five dozen liquor jugs",
    "Discover places worth the trip", "Settings Profile Saved Explore", "Sign in with your email address",
    "0123456789 12.50 4.8 1,234 reviews", "Über Größe Straße Café naïve", "WANDER AUTUMN MENU ADOPTION DAY",
]


def rnd(v):
    return math.floor(v + 0.5)


# Faces whose lines Text Kit gives a fifth more above, as the fine sweep of sizes shows.
fifth = set()
for k, v in mac.items():
    if k.startswith('fine/'):
        _, fam, face, size = k.split('/')
        upem, a = units[f'{fam}/{face}'][:2]
        if abs(v[1] - rnd(a / upem * float(size))) > 0.001:
            fifth.add(f'{fam}/{face}')

# Spacing per face and size: least squares over the words, each letter spaced alike.
rows = {}
for k, m in mac.items():
    if k.startswith('corpus/') and k in win:
        _, i, fam, face, size = k.split('/')
        rows.setdefault(f'{fam}/{face}', {}).setdefault(float(size), []).append((len(CORPUS[int(i)]), m[0], win[k][0]))
fits = {}
for key, sizes in rows.items():
    per = {s: sum(n * (wm - ww) for n, wm, ww in r) / (s * sum(n * n for n, _, _ in r)) for s, r in sizes.items()}
    flat = [(s, n, wm, ww) for s, r in sizes.items() for n, wm, ww in r]
    one = sum(n * s * (wm - ww) for s, n, wm, ww in flat) / sum((n * s) ** 2 for s, n, wm, ww in flat)
    fits[key] = (one, per)

print('    static let faces: [String: Face] = [')
for key in sorted(units):
    upem, a, d, l = units[key][:4]
    if all(abs(v - round(v)) < 1e-6 for v in (a, d, l)):
        args = f'{round(a)}, {round(d)}, {round(l)}, of: {upem:.0f}'
    else:
        args = ', '.join(repr(v / upem) if abs(v) > 1e-9 else '0' for v in (a, d, l))
    print(f'        "{key}": Face({args}{", fifth: true" if key in fifth else ""}),')
print('    ]\n')
print('    static let systemSpacings: [String: [Int]] = [')
for key in sorted(k for k in fits if k.startswith('System/')):
    per = fits[key][1]
    print(f'        "{key[7:]}": [{", ".join(str(round(max(-0.04, min(0.04, per[float(s)])) * 10000)) for s in SIZES)}],')
print('    ]\n')
print('    static let spacings: [String: Int] = [')
for key in sorted(k for k in fits if not k.startswith('System/')):
    c = round(max(-0.03, min(0.03, fits[key][0])) * 10000)
    if abs(c) >= 10:
        print(f'        "{key}": {c},')
print('    ]')
