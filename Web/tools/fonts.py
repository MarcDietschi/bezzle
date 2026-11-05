"""Copies the Mac fonts the sample designs use into site/fonts, for testing on this Mac only.

These are Apple's fonts: they may be used here, never published. site/fonts is git-ignored and
deploy must leave it out. Each face of a collection is written as a font of its own, named
"<family>|<face>" as the Mac's font manager names them, and SF Pro is kept whole, variable, with
its tracking table (trak) and named weights written into the manifest.

Run with the fontTools venv:  python -I tools/fonts.py
"""
import json, os, sys
from fontTools.ttLib import TTFont, TTCollection

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, '..', 'site', 'fonts')
os.makedirs(out, exist_ok=True)

collections = {
    'Avenir Next': '/System/Library/Fonts/Avenir Next.ttc',
    'Futura': '/System/Library/Fonts/Supplemental/Futura.ttc',
    'Bodoni 72': '/System/Library/Fonts/Supplemental/Bodoni 72.ttc',
}

def names(font):
    n = font['name']
    family = n.getDebugName(16) or n.getDebugName(1)
    face = n.getDebugName(17) or n.getDebugName(2)
    return family, face

manifest = {'faces': [], 'families': {}}
for family, path in collections.items():
    for i, font in enumerate(TTCollection(path).fonts):
        fam, face = names(font)
        if fam != family:
            # Members such as "Avenir Next Demi Bold" / "Regular" are named by their typographic names.
            continue
        file = f'{family}-{face}.ttf'.replace(' ', '_')
        font.save(os.path.join(out, file))
        manifest['faces'].append({'family': family, 'face': face, 'file': file})
        manifest['families'].setdefault(family, []).append(face)

sf = TTFont('/System/Library/Fonts/SFNS.ttf')
sf.save(os.path.join(out, 'SFNS.ttf'))
upem = sf['head'].unitsPerEm
track = sf['trak'].horizData[0.0]
weights = {sf['name'].getDebugName(i.subfamilyNameID): i.coordinates['wght'] for i in sf['fvar'].instances
           if i.coordinates.get('wdth') == 100.0}
manifest['system'] = {'file': 'SFNS.ttf', 'upem': upem, 'trak': sorted(track.items()), 'weights': weights,
                      'opsz': [a.minValue for a in sf['fvar'].axes if a.axisTag == 'opsz'] + [a.maxValue for a in sf['fvar'].axes if a.axisTag == 'opsz']}
json.dump(manifest, open(os.path.join(out, 'manifest.json'), 'w'), indent=1)
print(len(manifest['faces']), 'faces;', 'families', {k: len(v) for k, v in manifest['families'].items()})
