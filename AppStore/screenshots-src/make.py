#!/usr/bin/env python3
"""Builds the Mac App Store screenshots (2880×1800) from the artboards designed in Claude Design.

The canvas is https://claude.ai/artifact/K7FL4PdKY69TqcdmQoRaRn; its files are kept in canvas/project/. The English
artboards there (Main.dc.html, 02-adapt.dc.html … 10-ai.dc.html) are the masters: each is one 1440×900 slide, its words
marked with data-k, its pictures uploaded to the canvas as /_blob/<id> (blobs.json says which local file each one is).

  make.py localize      writes de-01-hero.dc.html … it-10-ai.dc.html from the masters, with the words from captions.py,
                        that locale's window pictures and the type fitted to the room it has; publish them to the canvas
  make.py render [loc]  renders every locale's artboards to ../screenshots/<locale>/01.png … 10.png at 2x, from the same
                        HTML the canvas shows, with the original PNGs in place of the canvas's WebP uploads
  make.py webp loc      writes that locale's window pictures as WebP into a folder, for uploading to the canvas

The window pictures in assets/<locale>/ come from capture/capture.py. Needs Playwright, which drives Google Chrome:
  python3 -m venv .venv && .venv/bin/pip install playwright pillow   (then run this with .venv/bin/python)
"""
import html, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from captions import COPY, ORDER  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.join(HERE, "canvas", "project")
ASSETS = os.path.join(HERE, "assets")
OUT = os.path.join(os.path.dirname(HERE), "screenshots")
BLOBS = os.path.join(HERE, "blobs.json")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MASTERS = ["Main.dc.html", "02-adapt.dc.html", "03-components.dc.html", "04-dark.dc.html", "05-prototype.dc.html",
           "06-inspect.dc.html", "07-deck.dc.html", "08-together.dc.html", "09-cutout.dc.html", "10-ai.dc.html"]
SHORT = {"de-DE": "de", "fr-FR": "fr", "it": "it"}
LANG = {"en-US": "en", "de-DE": "de", "fr-FR": "fr", "it": "it"}

# Fits the headline's lines into data-fit pixels and the line under it into data-lines lines, smaller step by step.
FIT = """() => {
  const out = {};
  const h = document.querySelector('h1[data-fit]');
  if (h) {
    const max = parseFloat(h.dataset.fit), ratio = parseFloat(getComputedStyle(h).lineHeight) / parseFloat(getComputedStyle(h).fontSize);
    const width = el => { const r = document.createRange(); r.selectNodeContents(el); return r.getBoundingClientRect().width; };
    const lines = [...h.querySelectorAll('[data-k]')];
    let size = parseFloat(getComputedStyle(h).fontSize);
    while (size > 36 && lines.some(l => width(l) > max)) { size -= 1; h.style.fontSize = size + 'px'; h.style.lineHeight = Math.round(size * ratio) + 'px'; }
    out.h1 = [h.style.fontSize, h.style.lineHeight];
  }
  const p = document.querySelector('p[data-lines]');
  if (p) {
    const n = parseInt(p.dataset.lines), ratio = parseFloat(getComputedStyle(p).lineHeight) / parseFloat(getComputedStyle(p).fontSize);
    let size = parseFloat(getComputedStyle(p).fontSize);
    const lh = () => parseFloat(getComputedStyle(p).lineHeight);
    while (size > 15 && p.getBoundingClientRect().height > n * lh() + 2) { size -= 0.5; p.style.fontSize = size + 'px'; p.style.lineHeight = Math.round(size * ratio) + 'px'; }
    out.sub = [p.style.fontSize, p.style.lineHeight];
  }
  return out;
}"""


def blobs():
    return json.load(open(BLOBS))


def plain(source, mapping):
    """The artboard as an ordinary page: its helmet in the head, no runtime, local pictures."""
    s = source.replace('<script src="./support.js"></script>', "")
    helmet = re.search(r"<helmet>(.*?)</helmet>", s, re.S).group(1)
    s = re.sub(r"<helmet>.*?</helmet>", "", s, flags=re.S).replace("</head>", helmet + "</head>")
    s = re.sub(r'<script type="text/x-dc".*?</script>', "", s, flags=re.S).replace("<x-dc>", "").replace("</x-dc>", "")
    for blob, path in mapping.items():
        s = s.replace(blob, "file://" + os.path.join(ASSETS, path))
    return s


def words(locale, master):
    """data-k → text for one slide in one language."""
    c = COPY[locale]
    key = ORDER[MASTERS.index(master)]
    entry = c[key]
    kicker, title, sub = (None, *entry) if len(entry) == 2 else entry
    a, b = title.split("\n")
    w = {"h1a": a, "h1b": b, "sub": sub}
    if kicker:
        w["kicker"] = kicker
    if key == "ai":
        w.update({"ai_title": c["ai_title"], "ai_prompt": c["ai_prompt"], "ai_done": c["ai_done"]})
        w.update({f"ai_step{i + 1}": s for i, s in enumerate(c["ai_steps"])})
    return w


def localized(locale, master, mapping):
    s = open(os.path.join(PROJECT, master)).read()
    s = s.replace('<html lang="en">', f'<html lang="{LANG[locale]}">')
    for k, text in words(locale, master).items():
        s, n = re.subn(rf'(<(\w+)[^>]*data-k="{k}"[^>]*>)(.*?)(</\2>)', lambda m: m.group(1) + html.escape(text, quote=False) + m.group(4), s, count=1, flags=re.S)
        if not n:
            raise SystemExit(f"{master}: no data-k={k}")
    by_path = {path: blob for blob, path in mapping.items()}
    for blob in set(re.findall(r"/_blob/[0-9a-f]{32}", s)):
        path = mapping.get(blob, "")
        if path.startswith("en-US/"):
            other = by_path.get(locale + path[5:])
            if not other:
                raise SystemExit(f"{locale}{path[5:]} is not on the canvas yet: upload it and add it to blobs.json")
            s = s.replace(blob, other)
    return s


def fitted(page, source, mapping, tmp):
    """Fits the type in the browser and writes the sizes it ended at into the artboard."""
    open(tmp, "w").write(plain(source, mapping))
    page.goto("file://" + tmp)
    page.wait_for_load_state("networkidle")
    page.evaluate("document.fonts.ready")
    sizes = page.evaluate(FIT)
    if sizes.get("h1") and sizes["h1"][0]:
        source = re.sub(r'(<h1 data-fit="\d+" style="[^"]*?)font-size: [\d.]+px; line-height: [\d.]+px;',
                        rf'\g<1>font-size: {sizes["h1"][0]}; line-height: {sizes["h1"][1]};', source, count=1)
    if sizes.get("sub") and sizes["sub"][0]:
        source = re.sub(r'(<p data-k="sub" data-lines="\d+" style="[^"]*?)font-size: [\d.]+px; line-height: [\d.]+px;',
                        rf'\g<1>font-size: {sizes["sub"][0]}; line-height: {sizes["sub"][1]};', source, count=1)
    return source, sizes


def name(locale, i):
    return MASTERS[i] if locale == "en-US" else f"{SHORT[locale]}-{i + 1:02d}-{ORDER[i]}.dc.html"


def localize(locales):
    from playwright.sync_api import sync_playwright
    mapping = blobs()
    tmp = os.path.join(HERE, ".fit.html")
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path=CHROME)
        page = b.new_page(viewport={"width": 1440, "height": 900})
        for locale in locales:
            for i, master in enumerate(MASTERS):
                source, sizes = fitted(page, localized(locale, master, mapping), mapping, tmp)
                open(os.path.join(PROJECT, name(locale, i)), "w").write(source)
                print(locale, name(locale, i), sizes or "")
        b.close()
    os.remove(tmp)


def render(locales):
    from playwright.sync_api import sync_playwright
    mapping = blobs()
    tmp = os.path.join(HERE, ".render.html")
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path=CHROME)
        page = b.new_page(viewport={"width": 1440, "height": 900}, device_scale_factor=2)
        for locale in locales:
            folder = os.path.join(OUT, locale)
            os.makedirs(folder, exist_ok=True)
            for f in os.listdir(folder):
                if f.endswith(".png"):
                    os.remove(os.path.join(folder, f))
            for i in range(len(MASTERS)):
                source = open(os.path.join(PROJECT, name(locale, i))).read()
                open(tmp, "w").write(plain(source, mapping))
                page.goto("file://" + tmp)
                page.wait_for_load_state("networkidle")
                page.evaluate("document.fonts.ready")
                page.wait_for_timeout(200)
                if not page.evaluate("document.fonts.check('600 60px Newsreader')"):
                    raise SystemExit("Newsreader did not load (no network?)")
                left = page.evaluate(FIT)  # nothing should change: the artboard holds fitted sizes
                page.screenshot(path=os.path.join(folder, f"{i + 1:02d}.png"))
                print(locale, f"{i + 1:02d}.png", left)
        b.close()
    os.remove(tmp)


def webp(locale, out):
    from PIL import Image
    os.makedirs(out, exist_ok=True)
    for f in sorted(os.listdir(os.path.join(ASSETS, locale))):
        if f.endswith(".png") and not re.match(r"together-\d", f) and f not in ("player.png", "home.png"):
            Image.open(os.path.join(ASSETS, locale, f)).save(os.path.join(out, f[:-4] + ".webp"), quality=90, method=6)
            print(os.path.join(out, f[:-4] + ".webp"))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    step, rest = sys.argv[1], sys.argv[2:]
    if step == "localize":
        localize(rest or ["de-DE", "fr-FR", "it"])
    elif step == "render":
        render(rest or ["en-US", "de-DE", "fr-FR", "it"])
    elif step == "webp":
        webp(rest[0], rest[1])
    else:
        raise SystemExit(__doc__)
