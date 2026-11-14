#!/bin/zsh
# Puts the browser version on Bezzle's website, at bezzle.ch/app/: the page a design's link opens
# (site/shared.html), its modules, the core and CanvasKit gzipped (the page unpacks them, and the
# website's .htaccess serves them as they are), and the open fonts in place of Apple's
# (tools/openfonts.py).
# It writes into the website's repository and leaves committing and pushing to whoever runs it.
#
#   ./publish.sh [~/Sites/bezzle-web]
set -euo pipefail
cd "${0:A:h}"
SITE="${1:-$HOME/Sites/bezzle-web}"
APP="$SITE/public/app"
[ -d "$SITE/public" ] || { echo "No website repository at $SITE" >&2; exit 1; }

./build.sh -c release -Xswiftc -Osize -Xlinker --strip-all
[ -f site/openfonts/manifest.json ] || { echo "Make the open fonts first: python -I tools/openfonts.py (with fontTools)" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/canvaskit" "$APP/fonts"
sed 's/^const published = false$/const published = true/' site/shared.html > "$APP/index.html"
grep -q '^const published = true$' "$APP/index.html" || { echo "The page did not take the published paths" >&2; exit 1; }
cp site/bezzle.mjs site/share.mjs site/film.mjs site/live.mjs site/shaders.mjs "$APP/"
gzip -9 -c .build/out/Products/Release-webassembly-wasm32/BezzleCore.wasm > "$APP/core.wasm.gz"
cp node_modules/canvaskit-wasm/bin/canvaskit.js "$APP/canvaskit/"
gzip -9 -c node_modules/canvaskit-wasm/bin/canvaskit.wasm > "$APP/canvaskit/canvaskit.wasm.gz"
cp site/openfonts/* "$APP/fonts/"
# Never Apple's fonts.
! grep -q '"SFNS' "$APP/fonts/manifest.json"
du -sh "$APP" "$APP/core.wasm.gz" "$APP/canvaskit/canvaskit.wasm.gz" "$APP/fonts"
