"""Packs Lucide, Phosphor and Material Symbols (Rounded) into one deflated JSON for Bezzle."""
import json, re, sys, zlib, os

dl = sys.argv[1]
out = sys.argv[2]

def num(v):
    f = float(v)
    s = ('%.3f' % f).rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s

NUMBER = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'

def absolute_start(d):
    """A path's first move is absolute even when written "m"; joined to others it would not be.
    The pairs after it are lines relative to it, so they keep a "l" of their own."""
    d = d.strip()
    if not d.startswith('m'):
        return d
    m = re.match(r'm\s*(' + NUMBER + r')[\s,]*(' + NUMBER + r')', d)
    rest = d[m.end():]
    head = 'M%s %s' % (m.group(1), m.group(2))
    if re.match(r'[\s,]*' + NUMBER, rest):
        return head + 'l' + rest.lstrip(' ,')
    return head + rest

def lucide_path(el):
    kind, a = el
    g = lambda k, d=0: float(a.get(k, d))
    if kind == 'path':
        return absolute_start(a['d'])
    if kind == 'circle' or kind == 'ellipse':
        cx, cy = g('cx'), g('cy')
        rx = g('r') if kind == 'circle' else g('rx')
        ry = g('r') if kind == 'circle' else g('ry')
        return 'M%s %sA%s %s 0 1 0 %s %sA%s %s 0 1 0 %s %sZ' % (num(cx - rx), num(cy), num(rx), num(ry), num(cx + rx), num(cy), num(rx), num(ry), num(cx - rx), num(cy))
    if kind == 'rect':
        x, y, w, h = g('x'), g('y'), g('width'), g('height')
        rx = float(a.get('rx', a.get('ry', 0))); ry = float(a.get('ry', a.get('rx', 0)))
        rx, ry = min(rx, w / 2), min(ry, h / 2)
        if rx <= 0:
            return 'M%s %sH%sV%sH%sZ' % (num(x), num(y), num(x + w), num(y + h), num(x))
        return ('M%s %sH%sA%s %s 0 0 1 %s %sV%sA%s %s 0 0 1 %s %sH%sA%s %s 0 0 1 %s %sV%sA%s %s 0 0 1 %s %sZ' % (
            num(x + rx), num(y), num(x + w - rx), num(rx), num(ry), num(x + w), num(y + ry), num(y + h - ry),
            num(rx), num(ry), num(x + w - rx), num(y + h), num(x + rx), num(rx), num(ry), num(x), num(y + h - ry),
            num(y + ry), num(rx), num(ry), num(x + rx), num(y)))
    if kind == 'line':
        return 'M%s %sL%s %s' % (num(g('x1')), num(g('y1')), num(g('x2')), num(g('y2')))
    if kind in ('polyline', 'polygon'):
        pts = [float(p) for p in re.split(r'[\s,]+', a['points'].strip())]
        pairs = ['%s %s' % (num(pts[i]), num(pts[i + 1])) for i in range(0, len(pts) - 1, 2)]
        return 'M' + 'L'.join(pairs) + ('Z' if kind == 'polygon' else '')
    raise ValueError(kind)

def svg_paths(file):
    s = open(file).read()
    ds = re.findall(r'<path[^>]*\sd="([^"]+)"', s)
    if not ds or re.search(r'<(circle|rect|line|polyline|polygon|ellipse)\b', s):
        raise ValueError('unexpected svg ' + file)
    return ''.join(ds)

sets = []

# What interfaces use most, first, so a set opens on what is wanted; the rest follow by name.
COMMON = {
    'lucide': """house search settings user bell heart star plus x check chevron-right chevron-left chevron-down chevron-up
        arrow-right arrow-left arrow-up arrow-down menu ellipsis ellipsis-vertical trash pencil share-2 share download upload
        calendar clock mail phone camera image map-pin lock lock-open eye eye-off funnel sliders-horizontal bookmark
        message-circle send shopping-cart shopping-bag credit-card globe wifi battery sun moon cloud play pause
        mic video file file-text folder link copy refresh-cw log-out log-in info circle-alert circle-question-mark
        circle-check circle-x circle-plus circle-user-round users map compass navigation thumbs-up gift tag
        list layout-grid grid-2x2 external-link maximize-2 minimize-2 zoom-in zoom-out volume-2 headphones printer
        smartphone laptop monitor bell-ring flag award trophy zap sparkles""".split(),
    'phosphor': """house magnifying-glass gear user bell heart star plus x check caret-right caret-left caret-down caret-up
        arrow-right arrow-left arrow-up arrow-down list dots-three dots-three-vertical trash pencil-simple share-network
        export download-simple upload-simple calendar clock envelope phone camera image map-pin lock lock-open eye
        eye-slash funnel sliders-horizontal bookmark-simple chat-circle paper-plane-tilt shopping-cart shopping-bag
        credit-card globe wifi-high battery-full sun moon cloud play pause music-note microphone video-camera file
        file-text folder link copy arrows-clockwise sign-out sign-in info warning-circle question check-circle x-circle
        plus-circle user-circle users map-trifold compass navigation-arrow thumbs-up gift tag list-bullets squares-four
        arrow-square-out arrows-out arrows-in magnifying-glass-plus magnifying-glass-minus speaker-high headphones
        printer device-mobile laptop monitor bell-ringing flag medal trophy lightning sparkle""".split(),
}

def common_first(set_id, icons):
    order = {n: i for i, n in enumerate(COMMON.get(set_id, []))}
    missing = [n for n in order if n not in {r[0] for r in icons}]
    if missing:
        print('not in', set_id, missing)
    return sorted(icons, key=lambda r: (order.get(r[0], len(order)), r[0]))

# Lucide: stroked outlines, kept as their middle lines; Bezzle strokes them at the weight asked.
lu = os.path.join(dl, 'lucide/package')
nodes = json.load(open(os.path.join(lu, 'icon-nodes.json')))
tags = json.load(open(os.path.join(lu, 'tags.json')))
icons = []
for name in sorted(nodes):
    icons.append([name, ' '.join(tags.get(name, [])), ''.join(lucide_path(e) for e in nodes[name])])
sets.append({'id': 'lucide', 'name': 'Lucide', 'licence': 'ISC', 'box': [0, 0, 24, 24], 'stroke': 2,
             'styles': ['outline'], 'icons': common_first('lucide', icons)})

# Phosphor: five weights drawn as filled outlines.
ph = os.path.join(dl, 'phosphor/package')
js = open(os.path.join(ph, 'dist/index.mjs')).read()
meta = {}
for m in re.finditer(r'name: "([^"]+)",\s*pascal_name: "[^"]*",\s*(?:alias: \{[^}]*\},\s*)?categories: \[[^\]]*\],\s*figma_category: [^,]+,\s*tags: \[([^\]]*)\]', js):
    meta[m.group(1)] = ' '.join(t for t in re.findall(r'"([^"]*)"', m.group(2)) if not t.startswith('*'))
weights = ['thin', 'light', 'regular', 'bold', 'fill']
icons = []
for f in sorted(os.listdir(os.path.join(ph, 'assets/regular'))):
    name = f[:-4]
    row = [name, meta.get(name, '')]
    for w in weights:
        fn = name + ('' if w == 'regular' else '-' + w) + '.svg'
        row.append(svg_paths(os.path.join(ph, 'assets', w, fn)))
    icons.append(row)
sets.append({'id': 'phosphor', 'name': 'Phosphor', 'licence': 'MIT', 'box': [0, 0, 256, 256],
             'styles': weights, 'icons': common_first('phosphor', icons)})
print('phosphor tagged', sum(1 for r in icons if r[1]), 'of', len(icons))

# Material Symbols Rounded: outlined and filled, most used first.
ma = os.path.join(dl, 'material/package/rounded')
gm = open(os.path.join(dl, 'gmeta/icons.json')).read()
gm = json.loads(gm[gm.index('{'):])
info = {i['name']: i for i in gm['icons']}
icons = []
names = sorted({f[:-4] for f in os.listdir(ma) if not f.endswith('-fill.svg')})
for name in names:
    fill = os.path.join(ma, name + '-fill.svg')
    i = info.get(name, {})
    icons.append((-(i.get('popularity') or 0), name, [name, ' '.join(i.get('tags', []) + i.get('categories', [])).replace('_', ' '),
                  svg_paths(os.path.join(ma, name + '.svg')), svg_paths(fill) if os.path.exists(fill) else '']))
icons.sort()
sets.append({'id': 'material', 'name': 'Material Symbols', 'licence': 'Apache-2.0', 'box': [0, -960, 960, 960],
             'styles': ['outline', 'fill'], 'icons': [r[2] for r in icons]})
print('material tagged', sum(1 for r in icons if r[2][1]), 'of', len(icons))

raw = json.dumps({'sets': sets}, separators=(',', ':')).encode()
c = zlib.compressobj(9, zlib.DEFLATED, -15)
packed = c.compress(raw) + c.flush()
open(out, 'wb').write(packed)
print('icons', [len(s['icons']) for s in sets], 'raw', len(raw), 'packed', len(packed))
