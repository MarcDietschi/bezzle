#!/usr/bin/env python3
"""Builds the Mac App Store screenshots (2880×1800) from real captures of Bezzle, in its own look:
warm paper, near-black ink, the blue pencil, New York for headlines.
The window pictures in assets/<locale>/ are 2x captures of the real app with its interface in that language,
made by capture/capture.py from the sample designs in designs/. Shared pictures (icon, posts) sit in assets/.
The words around them are in captions.py.
Usage: make.py [locale ...] [--only slide,slide]"""
import html, math, os, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from captions import COPY  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
A = "file://" + os.path.join(HERE, "assets") + "/"
OUT = os.path.join(os.path.dirname(HERE), "screenshots")
WINDOWS = A
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ORDER = ["hero", "controls", "deck", "cutout", "best", "grid", "depth", "together", "ai"]

CSS = """
@font-face { font-family: "NY"; src: url("file:///System/Library/Fonts/NewYork.ttf"); font-weight: 1 1000; }
:root { --ink:#1C1B19; --ink2:rgba(28,27,25,.62); --ink3:rgba(28,27,25,.42); --pencil:#3559C7; --card:#FCFBF8; }
body.dark { --ink:#F4F0E8; --ink2:rgba(244,240,232,.64); --pencil:#8FA8F4;
  background: radial-gradient(1200px 820px at 50% -4%, #35302A 0%, #211E1A 50%, #151311 100%); }
body.dark::after { mix-blend-mode:screen; opacity:.22; }
body.dark .win { filter: drop-shadow(0 0 .6px rgba(255,255,255,.55)) drop-shadow(0 40px 80px rgba(0,0,0,.55)) drop-shadow(0 4px 12px rgba(0,0,0,.4)); }
body.dark .post { box-shadow:0 0 0 .5px rgba(255,255,255,.12), 0 28px 56px rgba(0,0,0,.5), 0 2px 6px rgba(0,0,0,.35); }
* { box-sizing: border-box; }
html, body { margin:0; width:1440px; height:900px; overflow:hidden; }
body { position:relative; color:var(--ink); font-family:-apple-system, system-ui, sans-serif; -webkit-font-smoothing:antialiased;
  background: radial-gradient(1300px 900px at 16% 8%, #F9F7F2 0%, #F0EDE7 52%, #E7E2D8 100%); }
body::after { content:""; position:absolute; inset:0; pointer-events:none; opacity:.5; mix-blend-mode:multiply;
  background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='240' height='240'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 .23  0 0 0 0 .2  0 0 0 0 .15  0 0 0 .05 0'/></filter><rect width='240' height='240' filter='url(%23n)'/></svg>"); }
.text { position:absolute; z-index:5; }
.kicker { font-weight:650; font-size:15px; letter-spacing:.16em; color:var(--pencil); margin:0 0 20px; }
h1 { font-family:"NY", serif; font-weight:720; font-size:74px; line-height:1.02; letter-spacing:-.022em; margin:0; }
h1 .l { display:table; white-space:nowrap; }
.center h1 .l, h1.center .l { margin:0 auto; }
.mark { position:relative; display:inline-block; }
.mark svg { position:absolute; left:-1.5%; width:103%; bottom:-.2em; height:.32em; overflow:visible; }
.mark svg path { stroke:var(--pencil); }
p.sub { font-size:22.5px; line-height:1.46; color:var(--ink2); margin:26px 0 0; letter-spacing:-.003em; }
.center { text-align:center; }
.center p.sub { text-wrap:balance; max-width:1000px; margin-left:auto; margin-right:auto; }
p.sub { text-wrap:pretty; }
.win { position:absolute; filter: drop-shadow(0 38px 64px rgba(58,50,38,.27)) drop-shadow(0 3px 9px rgba(58,50,38,.13)); }
.win.dark { filter: drop-shadow(0 38px 64px rgba(20,16,10,.36)) drop-shadow(0 3px 9px rgba(20,16,10,.2)); }
.win > img { display:block; width:100%; }
.lights { position:absolute; left:0; top:0; width:1280px; height:60px; transform-origin:0 0; }
.lights i { position:absolute; top:18.75px; width:14px; height:14px; border-radius:50%; box-shadow:inset 0 0 0 .6px rgba(0,0,0,.16); }
.lights i:nth-child(1) { left:18.75px; background:#FF5F57; }
.lights i:nth-child(2) { left:41.75px; background:#FEBC2E; }
.lights i:nth-child(3) { left:64.75px; background:#28C840; }
.lights.idle i { background:#DAD6CF; box-shadow:inset 0 0 0 .6px rgba(0,0,0,.08); }
.lights.idle.dark i { background:#3D3B38; box-shadow:inset 0 0 0 .6px rgba(255,255,255,.06); }
.card { position:absolute; background:var(--card); border-radius:22px; box-shadow:0 0 0 .5px rgba(28,27,25,.1), 0 14px 34px rgba(58,50,38,.16), 0 1px 2px rgba(58,50,38,.1); }
.post { position:absolute; border-radius:14px; overflow:hidden; box-shadow:0 24px 50px rgba(30,20,10,.3), 0 2px 6px rgba(30,20,10,.18); }
.post img { display:block; width:100%; }
.pencil { position:absolute; overflow:visible; z-index:6; }
.pencil path { fill:none; stroke:var(--pencil); stroke-width:4.2; stroke-linecap:round; stroke-linejoin:round; }
.loupe { position:absolute; overflow:hidden; border-radius:22px; z-index:6; background:#F0EDE7;
  box-shadow:0 0 0 .5px rgba(28,27,25,.16), 0 34px 70px rgba(58,50,38,.30), 0 4px 12px rgba(58,50,38,.14); }
.loupe > img { position:absolute; display:block; max-width:none; }
.loupe svg { position:absolute; left:0; top:0; overflow:visible; }
.loupe svg path { fill:none; stroke:var(--pencil); stroke-linecap:round; }
"""

# A blue-pencil underline: one confident stroke and a lighter second pass, as a hand marks a sheet up.
MARK = """<svg viewBox="0 0 300 24" preserveAspectRatio="none"><path d="M3 15 C 70 8, 160 6, 297 10" stroke-width="6" fill="none" stroke-linecap="round" vector-effect="non-scaling-stroke" opacity=".92"/><path d="M28 20 C 110 15, 200 14, 282 16" stroke-width="3" fill="none" stroke-linecap="round" vector-effect="non-scaling-stroke" opacity=".55"/></svg>"""

FIT = """<script>
document.fonts.ready.then(() => {
  for (const h of document.querySelectorAll('h1[data-fit]')) {
    const max = parseFloat(h.dataset.fit); let size = parseFloat(getComputedStyle(h).fontSize);
    while (size > 40 && [...h.querySelectorAll('.l')].some(l => l.getBoundingClientRect().width > max)) { size -= 1; h.style.fontSize = size + 'px'; }
  }
  for (const p of document.querySelectorAll('p[data-lines]')) {
    const lines = parseInt(p.dataset.lines); let size = parseFloat(getComputedStyle(p).fontSize);
    const lh = () => parseFloat(getComputedStyle(p).lineHeight);
    while (size > 17 && p.getBoundingClientRect().height > lines * lh() + 2) { size -= .5; p.style.fontSize = size + 'px'; }
  }
  const t = document.querySelector('.text[data-avoid]');
  if (t) {
    const push = Math.max(0, t.getBoundingClientRect().bottom + 30 - parseFloat(t.dataset.avoid));
    for (const el of document.querySelectorAll('.below')) el.style.transform = `translateY(${push}px) ` + (el.style.transform || '');
  }
});
</script>"""


def e(s):
    return html.escape(s, quote=False)


def headline(text, fit, center=False):
    first, second = text.split("\n")
    return (f'<h1 data-fit="{fit}"{" class=center" if center else ""}><span class="l">{e(first)}</span>'
            f'<span class="l"><span class="mark">{e(second)}{MARK}</span></span></h1>')


def window(img, left, top, width, active=True, dark=False, z=1, native=1280, extra="", below=False):
    s = width / native
    # The front window is the active one; any behind it shows the grey lights of a window in the background.
    lights = f'<div class="lights{"" if active else " idle"}{" dark" if dark else ""}" style="transform:scale({s:.5f})"><i></i><i></i><i></i></div>'
    return (f'<div class="win{" dark" if dark else ""}{" below" if below else ""}" style="left:{left}px;top:{top}px;width:{width}px;z-index:{z};{extra}">'
            f'<img src="{WINDOWS}{img}.png">{lights}</div>')


def text_block(kicker, title, sub, left, top, width, fit=None, center=False, sub_lines=3, icon=False, valign=None, avoid=None):
    """avoid: the top of what sits below; it moves down when the words reach within 30 px of it (330 for centred text)."""
    style = f"left:{left}px;width:{width}px;" + (f"top:{top}px;" if valign is None else f"top:0;bottom:0;display:flex;flex-direction:column;justify-content:center;")
    if avoid is None and center:
        avoid = 330
    parts = [f'<div class="text{" center" if center else ""}"{f" data-avoid={avoid}" if avoid else ""} style="{style}">']
    if icon:
        parts.append(f'<img src="{A}icon.png" style="width:116px;margin:0 0 18px -12px;display:block">')
    if kicker:
        parts.append(f'<div class="kicker">{e(kicker)}</div>')
    parts.append(headline(title, fit or width, center))
    parts.append(f'<p class="sub" data-lines="{sub_lines}">{e(sub)}</p></div>')
    return "".join(parts)


def arrow(d, x, y, w, h, head):
    return (f'<svg class="pencil below" style="left:{x}px;top:{y}px" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
            f'<path d="{d}"/><path d="{head}"/></svg>')


def loupe(img, crop, k, left, top, marks="", below=False, z=6):
    """A part of a window picture (crop = x, y, w, h in window points) held up close, k CSS pixels per point."""
    x, y, w, h = crop
    return (f'<div class="loupe{" below" if below else ""}" style="left:{left}px;top:{top}px;width:{w * k:.1f}px;height:{h * k:.1f}px;z-index:{z}">'
            f'<img src="{WINDOWS}{img}.png" style="width:{1280 * k:.1f}px;left:{-x * k:.1f}px;top:{-y * k:.1f}px">'
            f'<svg width="{w * k:.0f}" height="{h * k:.0f}">{marks}</svg></div>')


def ring(cx, cy, rx, ry):
    """A blue-pencil loop around something, drawn in one go and overshooting where it closes, as a hand does."""
    pts = []
    for i in range(0, 47):
        a = math.radians(-160 + i * 8.6)
        wob = 1 + 0.035 * math.sin(i * 0.9)
        pts.append((cx + rx * wob * math.cos(a) + i * 0.12, cy + ry * wob * math.sin(a) - i * 0.08))
    d = "M" + " L".join(f"{px:.1f} {py:.1f}" for px, py in pts)
    return f'<path d="{d}" stroke-width="3.4" opacity=".92"/>'


def file_cards(spots):
    cards = []
    for i, (ext, label, x, y, rot) in enumerate(spots):
        cards.append(
            f'<div class="card below" style="left:{x}px;top:{y}px;width:212px;height:150px;transform:rotate({rot}deg);z-index:{3 + i};padding:22px 24px">'
            f'<svg width="34" height="42" viewBox="0 0 34 42"><path d="M5 1.5h16l11 11v24a4 4 0 0 1-4 4H5a4 4 0 0 1-4-4v-31a4 4 0 0 1 4-4z" fill="#EFEBE4" stroke="rgba(28,27,25,.35)" stroke-width="1.4"/><path d="M21 1.5v8a3 3 0 0 0 3 3h8" fill="none" stroke="rgba(28,27,25,.35)" stroke-width="1.4"/></svg>'
            f'<div style="font-family:NY;font-weight:700;font-size:38px;line-height:1;margin-top:14px;letter-spacing:-.02em">{ext}</div>'
            f'<div style="font-size:15px;color:var(--ink2);margin-top:6px">{e(label)}</div></div>')
    return "".join(cards)


# Slides on the dark ground; the rest sit on paper.
DARK = {"deck"}


def slide(name, c):
    if name == "hero":
        t, s = c["hero"]
        return (text_block(None, t, s, 96, 0, 490, fit=500, icon=True, valign=True, sub_lines=4)
                + window("cutout-dark", 744, 52, 740, active=False, dark=True)
                + window("hero", 612, 262, 816, z=2))
    if name == "controls":
        k, t, s = c["controls"]
        # The open Text card, close up: Frame, Text with its size stops, Opacity and Colour.
        return (text_block(k, t, s, 170, 58, 1100, fit=1100, center=True, sub_lines=2)
                + window("controls", 220, 336, 1000, below=True)
                + loupe("controls", (1006, 56, 266, 426), 1.12, 962, 346, ring(149, 207, 137, 21), below=True))
    if name == "best":
        k, t, s = c["best"]
        return (text_block(k, t, s, 170, 58, 1100, fit=1100, center=True, sub_lines=2)
                + window("home", 96, 336, 880, below=True)
                + file_cards([(".xd", "Adobe XD", 1052, 380, 6), (".fig", "Figma", 1178, 500, -5), (".sketch", "Sketch", 1040, 640, 3)])
                + arrow("M190 40 C 140 6, 60 10, 14 64", 860, 420, 200, 100, "M6 44 L13 66 L34 56"))
    if name == "deck":
        k, t, s = c["deck"]
        posts = [("post2", 64, 404, 236, -9, 1), ("post3", 168, 470, 236, -3, 2), ("post4", 1146, 396, 236, 8, 1), ("post5", 1040, 470, 236, 3, 2)]
        cards = "".join(f'<div class="post below" style="left:{x}px;top:{y}px;width:{w}px;transform:rotate({r}deg);z-index:{z}"><img src="{A}{p}.png"></div>' for p, x, y, w, r, z in posts)
        return (text_block(k, t, s, 170, 58, 1100, fit=1100, center=True, sub_lines=2)
                + cards + window("deck-dark", 300, 330, 840, dark=True, z=4, below=True))
    if name == "cutout":
        k, t, s = c["cutout"]
        # The Fill card close up, with Subject alone ringed.
        return (window("cutout", 52, 186, 846, z=2)
                + text_block(k, t, s, 960, 150, 400, fit=420, sub_lines=5)
                + loupe("cutout", (1006, 200, 266, 170), 1.2, 934, 604, ring(227, 121, 74, 23)))
    if name == "grid":
        k, t, s = c["grid"]
        return (text_block(k, t, s, 170, 58, 1100, fit=1100, center=True, sub_lines=2)
                + window("grid", 170, 330, 1100, below=True))
    if name == "depth":
        k, t, s = c["depth"]
        return (text_block(k, t, s, 96, 0, 420, fit=440, valign=True, sub_lines=5)
                + window("depth", 560, 112, 850, z=2))
    if name == "together":
        k, t, s = c["together"]
        a, b = c["names"]
        def tag(label, initial, color, x, y, below=False):
            return (f'<div class="card{" below" if below else ""}" style="left:{x}px;top:{y}px;z-index:7;border-radius:30px;padding:9px 18px 9px 9px;display:flex;align-items:center;gap:11px">'
                    f'<div style="width:36px;height:36px;border-radius:50%;background:{color};color:#fff;font:600 16px/36px -apple-system;text-align:center">{initial}</div>'
                    f'<div style="font-weight:600;font-size:17px">{e(label)}</div></div>')
        return (text_block(k, t, s, 96, 66, 560, fit=566, sub_lines=3, avoid=364)
                + window("wander-dark", 690, 64, 740, active=False, dark=True)
                + window("lea", 96, 392, 760, z=2, below=True)
                + tag(a, "L", "#3559C7", 74, 364, below=True)
                + tag(b, "N", "#E0673E", 1250, 40))
    if name == "ai":
        k, t, s = c["ai"]
        steps = "".join(
            f'<div style="display:flex;gap:12px;align-items:flex-start;margin-top:12px;font-size:16px;line-height:1.35;color:var(--ink)">'
            f'<svg width="18" height="18" viewBox="0 0 18 18" style="flex:none;margin-top:1px"><circle cx="9" cy="9" r="8.2" fill="#3559C7" opacity=".12"/><path d="M5 9.4l2.6 2.5L13 6.2" fill="none" stroke="#3559C7" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>'
            f'<span>{e(x)}</span></div>' for x in c["ai_steps"])
        chat = (f'<div class="card" style="left:548px;top:470px;width:460px;z-index:6;padding:22px 24px 22px">'
                f'<div style="display:flex;align-items:center;gap:9px;font-weight:600;font-size:15px;color:var(--ink2)">'
                f'<svg width="18" height="18" viewBox="0 0 24 24"><path d="M12 2.5l2.2 6.3 6.3 2.2-6.3 2.2L12 19.5l-2.2-6.3L3.5 11l6.3-2.2z" fill="#3559C7"/></svg>{e(c["ai_title"])}</div>'
                f'<div style="margin:16px 0 4px auto;max-width:360px;background:#1C1B19;color:#F6F4EF;border-radius:18px 18px 6px 18px;padding:13px 17px;font-size:16.5px;line-height:1.4">{e(c["ai_prompt"])}</div>'
                f'{steps}<div style="margin-top:16px;font-size:15px;color:var(--ink2)">{e(c["ai_done"])}</div></div>')
        return (text_block(k, t, s, 96, 0, 400, fit=420, valign=True, sub_lines=5).replace("justify-content:center", "justify-content:flex-start;padding-top:150px")
                + window("deck", 600, 96, 800, z=2) + chat)
    raise SystemExit(f"no slide {name}")


def build(locale, only=None):
    # Window pictures captured with the app in this language.
    global WINDOWS
    WINDOWS = A + locale + "/"
    c = COPY[locale]
    os.makedirs(os.path.join(OUT, locale), exist_ok=True)
    for i, name in enumerate(ORDER, 1):
        if only and name not in only:
            continue
        page = f'<!doctype html><html lang="{locale[:2]}"><head><meta charset="utf-8"><style>{CSS}</style></head><body{' class=dark' if name in DARK else ''}>{slide(name, c)}{FIT}</body></html>'
        src = os.path.join(tempfile.gettempdir(), f"bezzle-shot-{locale}-{i}.html")
        open(src, "w").write(page)
        png = os.path.join(OUT, locale, f"{i}.png")
        subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
                        "--force-device-scale-factor=2", "--window-size=1440,900", "--virtual-time-budget=4000",
                        f"--screenshot={png}", "file://" + src], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL, check=True)
        print(locale, i, name)


if __name__ == "__main__":
    args = sys.argv[1:]
    only = None
    if "--only" in args:
        only = args[args.index("--only") + 1].split(",")
        args = args[:args.index("--only")]
    for loc in args or list(COPY):
        build(loc, only)
