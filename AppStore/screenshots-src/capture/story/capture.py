#!/usr/bin/env python3
"""Captures the window for the story's two new chapters, in the manner of the app's AppStore/screenshots-src/capture/capture.py:
one launch per picture of a test copy with its own bundle id on a copy of a prepared design (prep.py) in a temporary
library, staged through the debug hooks, photographed with screencapture on a temporary HiDPI display.

Usage: capture.py [en de fr it] [--only vectorize,animate] [--out DIR]

For the website's story (mfrports/bezzle-web, public/img/app/<locale>/vectorize.webp and animate.webp; its
scripts/import-assets.sh says how the pictures go in). Kept here from the session that made them (2026-11-14) and not
run from this folder since. Beside this file it expects PeerStory.app, a Debug build of the app with a bundle id of its
own (never com.erik.Bezzle), tools/shot built from shot.swift here and tools/vd from ../vd.m, and designs/ as prep.py
makes them (run it, capture vectorize, run it again: the Animate design takes the logo the app traced).
"""
import os, re, shutil, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "PeerStory.app")
RELAY = os.environ.get("RELAY", "http://127.0.0.1:9")
LOCALES = {"en": "en-US", "de": "de-DE", "fr": "fr-FR", "it": "it"}
# No layer is ever picked in Animate on the way: Bezzle 1.8 (cf196be) crashes when a layer that shows a look to key (a
# fill, a shadow) is picked there and the camera is picked next (SelectionInspector.fillCard, LookCards.swift:163, and
# shadowCard, :387: `those[0]` of none, from FilmLooks.swift's ForEach; mended in 224f91a, for 1.8.1, so a copy built
# from there could pick the layers as the scene does). So the keys the scene's gestures make are set
# one by one: the pug's flight home, Drop for the four at the top, then the camera. The pug is picked and let go in
# Design first, so the list shows the poster's layers as it does once one of them has been picked.
def drop(name, t):
    return [f"key={name}:move:{t}:0,-36", f"key={name}:move:{t + 0.6:.2f}:0,0:spring", f"key={name}:fade:{t}:0", f"key={name}:fade:{t + 0.6:.2f}:1:out"]
STEPS = ["key=Pug:move:0:0,640", "key=Pug:move:0.5:0,0"] + drop("Date pill", 0) + drop("Where", 0.06) + drop("Date", 0.12) + drop("Good", 0.18)
FILM = ";".join([f"{5 + i * 0.12:.2f}:{step}" for i, step in enumerate(STEPS)] + ["8:seek=0.78", "8.5:pick=camera", "9:pose=cameraTilt:32", "9.5:pose=cameraSwing:-24"])
# Vectorize: the poster as the scene looks at it (75 %, its lower right corner on the table), the logo picked, traced
# at 6 s with its card opened after it.
SHOTS = {
    "vectorize": dict(env={"BEZZLE_LOOK": os.environ.get("LOOK_VECTORIZE", "Logo:0.75:-185,-219"), "BEZZLE_SELECT": "Logo", "BEZZLE_VECTORIZE": "6", "BEZZLE_CARD": "6.3:vector"}, wait=10.5, burst=(6.0, 8.6)),
    "animate": dict(env={"BEZZLE_SELECT": "Pug", "BEZZLE_CLICKS": "2:-300,-300", "BEZZLE_ANIMATE": "3.5", "BEZZLE_FILM": os.environ.get("FILM", FILM)}, wait=12.5),
}

def pids():
    return subprocess.run(["pgrep", "-f", os.path.join(APP, "Contents/MacOS/Bezzle")], capture_output=True, text=True).stdout.split()

def launch(lib, lang, env):
    # -g: in the background, never to the front. Its own library, no MCP server, and no relay it could reach: the
    # address is a closed port of this Mac. An empty one would do as well but for the bar at the top, which then has no
    # Share… button (Workspace.swift:205, Sharing.isAvailable), and every capture on the site shows it.
    args = ["open", "-g", "-n", "--env", f"BEZZLE_LIBRARY={lib}", "--env", "BEZZLE_APPEARANCE=light", "--env", f"BEZZLE_LIVE_RELAY={RELAY}", "--env", "BEZZLE_NO_MCP=1", "--env", "BEZZLE_WINDOW=1280x800"]
    for k, v in env.items():
        args += ["--env", f"{k}={v}"]
    before = set(pids())
    subprocess.run(args + [APP, "--args", "-AppleLanguages", f"({lang})", "-ApplePersistenceIgnoreState", "YES"], check=True)
    for _ in range(80):
        new = [p for p in pids() if p not in before]
        if new:
            return new[0]
        time.sleep(0.25)
    raise SystemExit("the app did not start")

def shot(pid, title, out):
    """Puts the window on the temporary display and photographs it. Returns the window's number."""
    for _ in range(4):
        r = subprocess.run([os.path.join(HERE, "tools", "shot"), str(pid), title, "1280", "800", out], env={**os.environ, "SETTLE": "0.6"}, capture_output=True, text=True)
        if "captured" in r.stdout:
            print(r.stdout.strip())
            return re.search(r"captured .*? (\d+)( display|$)", r.stdout.strip()).group(1)
        time.sleep(1.5)
    print(f"could not photograph {title}: {r.stdout} {r.stderr}")

if __name__ == "__main__":
    argv = sys.argv[1:]
    only, outdir = set(SHOTS), os.path.join(HERE, "out")
    if "--only" in argv:
        i = argv.index("--only"); only = set(argv[i + 1].split(",")); argv = argv[:i] + argv[i + 2:]
    if "--out" in argv:
        i = argv.index("--out"); outdir = argv[i + 1]; argv = argv[:i] + argv[i + 2:]
    langs = argv or ["en"]
    scratch = tempfile.mkdtemp(prefix="story-capture-", dir=HERE)
    display = subprocess.Popen([os.path.join(HERE, "tools", "vd"), "1600", "1000", "400"], stdout=subprocess.DEVNULL)
    time.sleep(3)
    try:
        for lang in langs:
            os.makedirs(os.path.join(outdir, LOCALES[lang]), exist_ok=True)
            for name, s in SHOTS.items():
                if name not in only:
                    continue
                lib = os.path.join(scratch, "lib")
                shutil.rmtree(lib, ignore_errors=True)
                shutil.copytree(os.path.join(HERE, "designs", name), lib)
                env = {"BEZZLE_OPEN": os.path.join(lib, "Adoption Day.bezzle"), **s["env"]}
                pid = launch(lib, lang, env)
                began = time.time()
                # off the main screen as soon as the window is there, and its number for the pictures to come
                time.sleep(1.6)
                final = os.path.join(outdir, LOCALES[lang], name + ".png")
                wid = shot(pid, "Adoption Day", os.path.join(scratch, "placed.png"))
                if wid and "burst" in s:
                    # the pencil's pass takes 0.85 s: a run of pictures over it, to choose from
                    time.sleep(max(0, began + s["burst"][0] - time.time()))
                    n = 0
                    while time.time() < began + s["burst"][1]:
                        subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", wid, os.path.join(outdir, LOCALES[lang], f"{name}-pass-{n:02d}.png")])
                        n += 1
                time.sleep(max(0, began + s["wait"] - time.time()))
                if wid:
                    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", wid, final])
                    print("photographed", final)
                if name == "vectorize":
                    time.sleep(0.8)   # the design is written 0.6 s after a change
                    shutil.copy(os.path.join(lib, "Adoption Day.bezzle", "document.json"), os.path.join(outdir, "vectorized.json"))
                subprocess.run(["kill", str(pid)])
                time.sleep(1.2)
    finally:
        display.terminate()
        for p in pids():
            subprocess.run(["kill", p])
        shutil.rmtree(scratch, ignore_errors=True)
