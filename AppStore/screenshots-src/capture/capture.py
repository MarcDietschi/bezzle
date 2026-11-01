#!/usr/bin/env python3
"""Captures the window pictures for the screenshots into ../assets/<locale>/, with the app's interface in that language.

Usage: capture.py PATH/TO/Bezzle.app [en de fr it] [--only shot,shot]   (a Debug build: the debug hooks stage each picture)

Each picture is one launch of a test copy on copies of ../designs in a temporary library, staged through the debug
hooks (BEZZLE_OPEN, BEZZLE_LOOK, BEZZLE_SELECT, BEZZLE_CARD, BEZZLE_PROTOTYPE, BEZZLE_INSPECT, BEZZLE_PLAY) and the
MCP server where a hook is not enough, then photographed with screencapture on a temporary HiDPI display left of the
main one, so the pictures come out at 2x on a 1x screen too. The terminal needs Accessibility and Screen Recording.

"together" also needs the live relay running (cd Relay && npm run dev); two more copies of the app with their own
bundle ids join the viewer there as Noah and Mia. Its design comes from ../shared/<locale>/, Wander Pitch made a
shared design (sharing/design.json and link.json, written by a throwaway test from DesignFile.read, SharedDesign.absorb
and SharingFiles.write) with the margin notes in that language; without it that picture is skipped.
"""
import json, os, shutil, subprocess, sys, tempfile, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGNS = os.path.join(os.path.dirname(HERE), "designs")
ASSETS = os.path.join(os.path.dirname(HERE), "assets")
SHARED = os.path.join(os.path.dirname(HERE), "shared")  # Wander Pitch as a shared design, its notes in each language
LOCALES = {"en": "en-US", "de": "de-DE", "fr": "fr-FR", "it": "it"}
TOOLS = os.path.join(tempfile.gettempdir(), "bezzle-capture")
SUITE = "com.erik.Bezzle.tests"  # Library.settings for a run with BEZZLE_LIBRARY
RELAY = "ws://127.0.0.1:8787"
sys.path.insert(0, os.path.dirname(HERE))
from captions import COPY  # noqa: E402

# One launch per picture: the design, how it is looked at (layer:zoom[:dx,dy]), what is selected, which card is out.
# `ids` selects through MCP where names are not unique (the copies of a component all share theirs).
SHOTS = {
    "hero": dict(design="Wander", look="Place:0.5:0,30", select=["Hero"], card="photo"),
    "adapt": dict(design="Adoption Day Sizes", look="Poster:0.135:720,-10", select=["Story"]),
    "components": dict(design="Wander", look="Explore:0.5:0,30", ids=["4379D256-95E2-8F9B-D7EC-5C20279AB885"], card="component"),
    "dark": dict(design="Wander Night", look="Place:0.36:0,470", select=["Place dark"], appearance="dark"),
    "prototype": dict(design="Wander", look="Place:0.5", prototype=True),
    "player": dict(design="Wander", play="Discover", wait=7),
    "inspect": dict(design="Wander", look="Place:0.78:0,130", select=["Book button"], inspect=True),
    "deck": dict(design="Ember & Oat", look="Autumn menu:0.42:0,275", select=["Autumn menu"], appearance="dark"),
    "cutout": dict(design="Adoption Day", look="Poster:0.42:0,275", select=["Pug"], card="photo"),
    "ai": dict(design="Ember & Oat", look="Autumn menu:0.42:0,275", select=["Autumn menu"]),
    "home": dict(design=None, size=(1320, 880)),
}


def tools():
    """vd (the virtual display), shot (move a window there and photograph it) and press (AXPress a card), built once."""
    os.makedirs(TOOLS, exist_ok=True)
    for name, src, cmd in (("vd", "vd.m", ["clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics"]),
                           ("shot", "shot.swift", ["xcrun", "swiftc", "-O"]), ("press", "press.swift", ["xcrun", "swiftc", "-O"])):
        out, source = os.path.join(TOOLS, name), os.path.join(HERE, src)
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(source):
            subprocess.run(cmd + [source, "-o", out], check=True)


def pids(app):
    out = subprocess.run(["pgrep", "-f", os.path.join(app, "Contents/MacOS/Bezzle")], capture_output=True, text=True).stdout
    return out.split()


def launch(app, lib, lang, env, look="light"):
    """Opens a test copy with these debug hooks and returns its pid."""
    # -g: in the background. A test copy must never come to the front or take focus from whoever works on this Mac.
    args = ["open", "-g", "-n", "--env", f"BEZZLE_LIBRARY={lib}", "--env", f"BEZZLE_APPEARANCE={look}"]
    for k, v in env.items():
        args += ["--env", f"{k}={v}"]
    before = set(pids(app))
    subprocess.run(args + [app, "--args", "-AppleLanguages", f"({lang})", "-ApplePersistenceIgnoreState", "YES"], check=True)
    for _ in range(80):
        new = [p for p in pids(app) if p not in before]
        if new:
            return new[0]
        time.sleep(0.25)
    raise SystemExit("the app did not start")


def mcp(port, name, **args):
    def call(method, params, n):
        body = json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", data=body, method="POST",
                                     headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    for _ in range(40):
        try:
            call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "capture", "version": "1"}}, 1)
            break
        except OSError:
            time.sleep(0.25)
    res = call("tools/call", {"name": name, "arguments": args}, 2)
    if "error" in res or res.get("result", {}).get("isError"):
        raise SystemExit(f"{name} {args}: {res}")
    return res


def shot(pid, title, w, h, out, settle):
    for _ in range(4):  # a slow launch may not have titled its window yet
        r = subprocess.run([os.path.join(TOOLS, "shot"), str(pid), title, str(w), str(h), out],
                           env={**os.environ, "SETTLE": str(settle)}, capture_output=True, text=True)
        if "captured" in r.stdout:
            return
        time.sleep(2.5)
    raise SystemExit(f"could not photograph {title}: {r.stdout} {r.stderr}")


def quit(pid):
    subprocess.run(["kill", str(pid)])
    time.sleep(1.2)


def fresh(scratch, name):
    lib = os.path.join(scratch, name)
    shutil.rmtree(lib, ignore_errors=True)
    shutil.copytree(DESIGNS, lib)
    return lib


def capture(app, lang, scratch, only):
    app = peer_app(app, "capture")  # its own bundle id: a background launch shows its window even while Bezzle itself runs
    out = os.path.join(ASSETS, LOCALES[lang])
    os.makedirs(out, exist_ok=True)
    port = 7461
    for name, s in SHOTS.items():
        if only and name not in only:
            continue
        lib = fresh(scratch, "lib")
        w, h = s.get("size", (1280, 800))
        env = {"BEZZLE_WINDOW": f"{w}x{h}", "BEZZLE_MCP_PORT": str(port)}
        if s["design"]:
            env["BEZZLE_OPEN"] = os.path.join(lib, s["design"] + ".bezzle")
        if "look" in s: env["BEZZLE_LOOK"] = s["look"]
        if "select" in s: env["BEZZLE_SELECT"] = ",".join(s["select"])
        if "card" in s: env["BEZZLE_CARD"] = f"4.2:{s['card']}"
        if s.get("prototype"): env["BEZZLE_PROTOTYPE"] = "1.2"
        if s.get("inspect"): env["BEZZLE_INSPECT"] = "1.2"
        if "play" in s: env["BEZZLE_PLAY"] = f"2:{s['play']}"
        pid = launch(app, lib, lang, env, s.get("appearance", "light"))
        if "ids" in s:
            time.sleep(2)
            mcp(port, "select_layers", design=s["design"], layers=s["ids"])
        time.sleep(s.get("wait", 5.5))
        shot(pid, s["design"] or "Bezzle", w, h, os.path.join(out, name + ".png"), 1.2)
        quit(pid)
        port += 1
    if not only or "together" in only:
        together(app, lang, scratch, out)
    print("captured", LOCALES[lang])


def peer_app(app, n):
    """A copy of the app with its own bundle id: the one photographed, and the others in the live room."""
    copy = os.path.join(TOOLS, f"Peer{n}.app")
    if not os.path.exists(copy) or os.path.getmtime(copy) < os.path.getmtime(app):
        shutil.rmtree(copy, ignore_errors=True)
        shutil.copytree(app, copy, symlinks=True)
        subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier com.erik.Bezzle.peer{n}", os.path.join(copy, "Contents/Info.plist")], check=True)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", copy], check=True, capture_output=True)
    return copy


def together(app, lang, scratch, out):
    """Wander Pitch shared with two others who are in it now: their pencils, a wink, and notes in the margin."""
    shared = os.path.join(SHARED, LOCALES[lang], "Wander Pitch.bezzle")
    if not os.path.exists(os.path.join(shared, "sharing", "design.json")):
        print("together: no shared sample design, skipped")
        return
    words = COPY[LOCALES[lang]]
    people = [("viewer", words["names"][0], None, 7471), ("noah", words["names"][1], (-250, -130), 7472), ("mia", words["names"][2], (210, 120), 7473)]
    pids_ = []
    for who, person, at, port in people:
        lib = os.path.join(scratch, "live-" + who)
        shutil.rmtree(lib, ignore_errors=True)
        os.makedirs(lib)
        shutil.copytree(shared, os.path.join(lib, "Wander Pitch.bezzle"))
        env = {"BEZZLE_OPEN": os.path.join(lib, "Wander Pitch.bezzle"), "BEZZLE_WINDOW": "1280x800", "BEZZLE_MCP_PORT": str(port),
               "BEZZLE_LIVE_RELAY": RELAY, "BEZZLE_LIVE_NAME": person, "BEZZLE_REPLICA": "shots-" + who}
        if at:
            env.update({"BEZZLE_LIVE_DEMO": "wink", "BEZZLE_LOOK": f"Presentation:0.45:{at[0]},{at[1]}"})
            pids_.append((launch(peer_app(app, who), lib, lang, env), None))
        else:
            env.update({"BEZZLE_LIVE_TAGS": "1", "BEZZLE_LOOK": "Presentation:0.42:420,100", "BEZZLE_WINDOW": "1440x900"})
            viewer = launch(app, lib, lang, env)  # already the capture copy
    time.sleep(9)
    # A wink comes every few seconds and fades; a few pictures a second apart, to pick the one with both loops drawn.
    for i in range(4):
        shot(viewer, "Wander Pitch", 1440, 900, os.path.join(out, f"together-{i + 1}.png"), 0.4)  # wider, for the margin notes
        time.sleep(0.6)
    for p, _ in pids_:
        quit(p)
    quit(viewer)


if __name__ == "__main__":
    argv = sys.argv[1:]
    only = set()
    if "--only" in argv:
        i = argv.index("--only")
        only = set(argv[i + 1].split(","))
        argv = argv[:i] + argv[i + 2:]
    if not argv:
        raise SystemExit(__doc__)
    app, langs = os.path.abspath(argv[0]), argv[1:] or ["en", "de", "fr", "it"]
    tools()
    scratch = tempfile.mkdtemp(prefix="bezzle-capture-")
    # The home screen lists designs remembered by test runs too; keep them off it while capturing.
    backup = os.path.join(scratch, "suite.plist")
    subprocess.run(["defaults", "export", SUITE, backup], check=True)
    for key in ("recentDesigns", "fileAccess"):
        subprocess.run(["defaults", "delete", SUITE, key], stderr=subprocess.DEVNULL)
    display = subprocess.Popen([os.path.join(TOOLS, "vd"), "1600", "1000", "3600"], stdout=subprocess.DEVNULL)
    time.sleep(3)
    try:
        for lang in langs:
            capture(app, lang, scratch, only)
    finally:
        display.terminate()
        subprocess.run(["defaults", "import", SUITE, backup])
