"""Makes the fonts a published page may use, in place of Apple's: open look-alikes for the Mac's
system font and the families designs are often set in, each face of each Mac family a static font
of its own at the face's weight, written into site/openfonts with their licenses and a manifest in
the shape site/fonts has (tools/fonts.py), so the page loads either the same way.

  SF Pro (the system font)                 Inter, variable, weight and optical size as SF's are set
  Avenir, Avenir Next                      Nunito Sans
  Futura                                   Jost
  Bodoni 72                                Libre Bodoni
  Helvetica, Helvetica Neue, Arial         Arimo (Arial's metrics)
  Times, Times New Roman                   Tinos (Times New Roman's metrics)
  Georgia                                  Gelasio (Georgia's metrics)
  Courier, Courier New, Menlo              Cousine (Courier New's metrics)
  Didot                                    Playfair Display
  Baskerville                              Libre Baskerville

The Mac's faces and their weights are in tools/mac-faces.json, as macOS's font manager lists them
(each face's OS/2 weight). The sources come from Google Fonts' repository, under the SIL Open Font
License, and are kept in .fonts-src.

Run with fontTools:  python -I tools/openfonts.py
"""
import json, os, re, urllib.request
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, '..')
cache = os.path.join(root, '.fonts-src')
out = os.path.join(root, 'site', 'openfonts')
os.makedirs(cache, exist_ok=True)
os.makedirs(out, exist_ok=True)
REPO = 'https://raw.githubusercontent.com/google/fonts/main/'

# Each open family: its upright and italic sources (variable, or static by weight), and its license.
SOURCES = {
    'Inter': {'dir': 'ofl/inter', 'upright': 'Inter[opsz,wght].ttf', 'italic': 'Inter-Italic[opsz,wght].ttf'},
    'Nunito Sans': {'dir': 'ofl/nunitosans', 'upright': 'NunitoSans[YTLC,opsz,wdth,wght].ttf', 'italic': 'NunitoSans-Italic[YTLC,opsz,wdth,wght].ttf'},
    'Jost': {'dir': 'ofl/jost', 'upright': 'Jost[wght].ttf', 'italic': 'Jost-Italic[wght].ttf'},
    'Libre Bodoni': {'dir': 'ofl/librebodoni', 'upright': 'LibreBodoni[wght].ttf', 'italic': 'LibreBodoni-Italic[wght].ttf'},
    'Arimo': {'dir': 'ofl/arimo', 'upright': 'Arimo[wght].ttf', 'italic': 'Arimo-Italic[wght].ttf'},
    'Tinos': {'dir': 'ofl/tinos', 'static': {(400, False): 'Tinos-Regular.ttf', (400, True): 'Tinos-Italic.ttf', (700, False): 'Tinos-Bold.ttf', (700, True): 'Tinos-BoldItalic.ttf'}},
    'Gelasio': {'dir': 'ofl/gelasio', 'upright': 'Gelasio[wght].ttf', 'italic': 'Gelasio-Italic[wght].ttf'},
    'Cousine': {'dir': 'ofl/cousine', 'static': {(400, False): 'Cousine-Regular.ttf', (400, True): 'Cousine-Italic.ttf', (700, False): 'Cousine-Bold.ttf', (700, True): 'Cousine-BoldItalic.ttf'}},
    'Playfair Display': {'dir': 'ofl/playfairdisplay', 'upright': 'PlayfairDisplay[wght].ttf', 'italic': 'PlayfairDisplay-Italic[wght].ttf'},
    'Libre Baskerville': {'dir': 'ofl/librebaskerville', 'upright': 'LibreBaskerville[wght].ttf', 'italic': 'LibreBaskerville-Italic[wght].ttf'},
}

STANDS_IN = {
    'Avenir Next': 'Nunito Sans', 'Avenir': 'Nunito Sans', 'Futura': 'Jost', 'Bodoni 72': 'Libre Bodoni',
    'Helvetica Neue': 'Arimo', 'Helvetica': 'Arimo', 'Arial': 'Arimo', 'Times New Roman': 'Tinos', 'Times': 'Tinos',
    'Georgia': 'Gelasio', 'Courier New': 'Cousine', 'Courier': 'Cousine', 'Menlo': 'Cousine',
    'Didot': 'Playfair Display', 'Baskerville': 'Libre Baskerville',
}


def fetch(dir, name):
    # A licence is kept by family: every family has an OFL.txt of its own, and a cache by name
    # alone gave all of them the first one's copyright line (every *-OFL.txt said Arimo's).
    path = os.path.join(cache, dir.replace('/', '-') + '-' + name if name == 'OFL.txt' else name)
    if not os.path.exists(path):
        url = REPO + dir + '/' + urllib.request.quote(name)
        with urllib.request.urlopen(url) as r, open(path, 'wb') as f:
            f.write(r.read())
    return path


def license_of(family):
    """The family's license file; for one without, its own copyright with the license's text."""
    src = SOURCES[family]
    try:
        return fetch(src['dir'], 'OFL.txt'), 'OFL.txt'
    except Exception:
        pass
    first = src['static'][(400, False)] if 'static' in src else src['upright']
    copyright = TTFont(fetch(src['dir'], first))['name'].getDebugName(0) or family
    body = open(fetch('ofl/inter', 'OFL.txt'), encoding='utf-8').read()
    body = body[body.index('This Font Software is licensed'):]
    path = os.path.join(cache, f"{family.replace(' ', '')}-OFL.txt")
    with open(path, 'w', encoding='utf-8') as f:
        f.write(copyright + '\n\n' + body)
    return path, 'OFL.txt'


def weight_of(face, weight):
    # Some faces say less than their names do (Courier's Bold says 400).
    if weight == 400 and re.search(r'\bBold\b', face) and 'Semi' not in face and 'Demi' not in face:
        return 700
    return weight


made = {}


def instance(family, weight, italic):
    """A static font of `family` at `weight`, italic or not; one file for each, however many faces ask."""
    key = (family, weight, italic)
    if key in made:
        return made[key]
    src = SOURCES[family]
    file = f"{family.replace(' ', '')}-{weight}{'-Italic' if italic else ''}.ttf"
    if 'static' in src:
        options = src['static']
        near = min(options, key=lambda k: (k[1] != italic, abs(k[0] - weight)))
        font = TTFont(fetch(src['dir'], options[near]))
    else:
        name = src['italic'] if italic and 'italic' in src else src['upright']
        font = TTFont(fetch(src['dir'], name))
        axes = {a.axisTag: a.defaultValue for a in font['fvar'].axes}
        wght = next(a for a in font['fvar'].axes if a.axisTag == 'wght')
        axes['wght'] = min(max(weight, wght.minValue), wght.maxValue)
        font = instancer.instantiateVariableFont(font, axes)
    font.save(os.path.join(out, file))
    made[key] = file
    return file


mac = json.load(open(os.path.join(here, 'mac-faces.json')))
manifest = {'faces': [], 'families': {}, 'standsIn': {}}
for family, faces in sorted(mac.items()):
    open_family = STANDS_IN.get(family)
    if not open_family:
        continue
    manifest['standsIn'][family] = open_family
    for face, weight, italic in faces:
        file = instance(open_family, weight_of(face, weight), bool(italic))
        manifest['faces'].append({'family': family, 'face': face, 'file': file})
        manifest['families'].setdefault(family, []).append(face)

# The system font stays variable, its weights named as SF Pro's are, its optical size as Inter has it.
inter = TTFont(fetch(SOURCES['Inter']['dir'], SOURCES['Inter']['upright']))
inter.save(os.path.join(out, 'Inter-Variable.ttf'))
opsz = next(a for a in inter['fvar'].axes if a.axisTag == 'opsz')
named = {'Ultralight': 100, 'Thin': 200, 'Light': 300, 'Regular': 400, 'Medium': 500, 'Semibold': 600, 'Bold': 700, 'Heavy': 800, 'Black': 900}
weights = {**named, **{f'{k} G{g}': v for k, v in named.items() for g in range(1, 5)}}
manifest['system'] = {'file': 'Inter-Variable.ttf', 'upem': inter['head'].unitsPerEm, 'trak': None,
                      'weights': weights, 'opsz': [opsz.minValue, opsz.maxValue], 'standsIn': 'SF Pro'}

licenses = {}
for family in sorted(set(manifest['standsIn'].values()) | {'Inter'}):
    path, name = license_of(family)
    target = f"{family.replace(' ', '')}-{name}"
    with open(path, 'rb') as a, open(os.path.join(out, target), 'wb') as b:
        b.write(a.read())
    licenses[family] = target
manifest['licenses'] = licenses

with open(os.path.join(out, 'manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=1)
size = sum(os.path.getsize(os.path.join(out, n)) for n in os.listdir(out))
print(f"{len(manifest['faces'])} faces of {len(manifest['families'])} Mac families in {len(made)} files, plus Inter; {size / 1e6:.1f} MB")
