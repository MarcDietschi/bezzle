#!/usr/bin/env python3
"""The Mac's words in other languages (Bezzle/Localizable.xcstrings), for Windows: one JSON file,
Resources/Generated/strings.json, {"de": {"Opacity": "Deckkraft", "%lld layers": {"one": ..,
"other": ..}, ...}, "fr": ..., "it": ...}. Only translated entries; a plural keeps its forms.
VM/sync.sh runs it when the catalog has changed."""
import json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
catalog = os.path.join(here, '..', '..', 'Bezzle', 'Localizable.xcstrings')
out = os.path.join(here, 'Generated', 'strings.json')
if os.path.exists(out) and os.path.getmtime(out) >= max(os.path.getmtime(catalog), os.path.getmtime(__file__)):
    sys.exit(0)
strings = json.load(open(catalog, encoding='utf-8'))['strings']
languages = {}
for key, entry in strings.items():
    for lang, loc in (entry.get('localizations') or {}).items():
        if lang == 'en':
            continue
        if 'stringUnit' in loc:
            unit = loc['stringUnit']
            if unit.get('state') in ('translated', 'needs_review') and unit.get('value'):
                languages.setdefault(lang, {})[key] = unit['value']
        elif 'variations' in loc and 'plural' in loc['variations']:
            forms = {k: v['stringUnit']['value'] for k, v in loc['variations']['plural'].items() if 'stringUnit' in v}
            if forms:
                languages.setdefault(lang, {})[key] = forms
os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump(languages, open(out, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'), sort_keys=True)
print(' '.join(f'{l}: {len(v)}' for l, v in sorted(languages.items())), '->', out)
