"""Lists the sample designs for the test page: site/samples.json."""
import json, os
here = os.path.dirname(os.path.abspath(__file__))
designs = os.path.join(here, '..', '..', 'AppStore', 'screenshots-src', 'designs')
out = []
for name in sorted(os.listdir(designs)):
    if not name.endswith('.bezzle'):
        continue
    images = os.path.join(designs, name, 'images')
    out.append({'name': name[:-7], 'images': sorted(os.listdir(images)) if os.path.isdir(images) else []})
json.dump(out, open(os.path.join(here, '..', 'site', 'samples.json'), 'w'), indent=1)
print(len(out), 'designs')
