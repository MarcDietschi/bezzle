#!/usr/bin/env python3
"""Captures the window pictures for the screenshots into ../assets/<locale>/, with the app's interface in that language.

Usage: capture.py PATH/TO/Bezzle.app [en de fr it]   (a Debug build; DebugHooks sets the appearance)

Runs each language twice, light and dark, on copies of ../designs in a temporary library, drives the app over its
MCP server, opens inspector cards through Accessibility (the terminal needs Accessibility and Screen Recording
access), and photographs each window with screencapture on a temporary HiDPI display left of the main one, so the
pictures come out at 2x on a 1x screen too. Takes about two minutes a language.
"""
import json, os, shutil, subprocess, sys, tempfile, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGNS = os.path.join(os.path.dirname(HERE), "designs")
ASSETS = os.path.join(os.path.dirname(HERE), "assets")
LOCALES = {"en": "en-US", "de": "de-DE", "fr": "fr-FR", "it": "it"}
TOOLS = os.path.join(tempfile.gettempdir(), "bezzle-capture")
SUITE = "com.erik.Bezzle.tests"  # Library.settings for a run with BEZZLE_LIBRARY


def tools():
    """vd (the virtual display), shot (move a window there and photograph it) and press (AXPress a card), built once."""
    os.makedirs(TOOLS, exist_ok=True)
    for name, src, cmd in (("vd", "vd.m", ["clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics"]),
                           ("shot", "shot.swift", ["xcrun", "swiftc", "-O"]), ("press", "press.swift", ["xcrun", "swiftc", "-O"])):
        out, source = os.path.join(TOOLS, name), os.path.join(HERE, src)
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(source):
            subprocess.run(cmd + [source, "-o", out], check=True)


class App:
    def __init__(self, app, lib, port, look, lang):
        self.port, self.id = port, 0
        subprocess.run(["open", "-n", "--env", f"BEZZLE_LIBRARY={lib}", "--env", f"BEZZLE_MCP_PORT={port}",
                        "--env", f"BEZZLE_APPEARANCE={look}", app, "--args", "-AppleLanguages", f"({lang})"], check=True)
        for _ in range(40):
            self.pid = subprocess.run(["lsof", "-tnP", f"-iTCP:{port}", "-sTCP:LISTEN"], capture_output=True, text=True).stdout.strip()
            if self.pid:
                break
            time.sleep(0.5)
        else:
            raise SystemExit(f"no app on port {port}")
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "capture", "version": "1"}})

    def rpc(self, method, params):
        self.id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.id, "method": method, "params": params}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/mcp", data=body, method="POST",
                                     headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
        with urllib.request.urlopen(req, timeout=120) as r:
            res = json.loads(r.read().decode())
        if "error" in res or res.get("result", {}).get("isError"):
            raise SystemExit(f"{method} {params}: {res}")
        return res

    def tool(self, name, **args):
        return self.rpc("tools/call", {"name": name, "arguments": args})

    def shot(self, title, w, h, out, settle=1.6):
        subprocess.run([os.path.join(TOOLS, "shot"), self.pid, title, str(w), str(h), out], env={**os.environ, "SETTLE": str(settle)}, check=True)

    def press(self, window, nth, expect=""):
        """Opens the nth card of the inspector (counted from the top, so it works in every language)."""
        r = subprocess.run([os.path.join(TOOLS, "press"), self.pid, window, f"#{nth}"], capture_output=True, text=True)
        if expect not in r.stdout or "press" not in r.stdout:
            raise SystemExit(f"pressed the wrong card in {window}: {r.stdout.strip()}")
        time.sleep(1.0)

    def quit(self):
        subprocess.run(["kill", self.pid])
        time.sleep(2)


def capture(app, lang, scratch):
    out = os.path.join(ASSETS, LOCALES[lang])
    os.makedirs(out, exist_ok=True)
    tmp = os.path.join(scratch, "tmp.png")
    for port, look in ((7461, "light"), (7462, "dark")):
        lib = os.path.join(scratch, look)
        shutil.rmtree(lib, ignore_errors=True)
        shutil.copytree(DESIGNS, lib)
        a = App(app, lib, port, look, lang)
        time.sleep(1.5)
        P = lambda name: os.path.join(out, name)
        if look == "light":
            a.shot("Bezzle", 1280, 800, P("home.png"), 2)
        names = ["Wander", "Ember & Oat", "Adoption Day"] + (["Wander Pitch"] if look == "light" else [])
        for d in names:
            a.tool("open_design", design=os.path.join(lib, d + ".bezzle"))
            time.sleep(0.8)
            a.shot(d, 1280, 800, tmp, 0.1)  # straight onto the virtual display
        time.sleep(1.5)
        if look == "light":
            a.tool("select_layers", design="Wander", layers=["Discover/Featured"])
            a.tool("view", design="Wander", zoom="fit"); a.tool("view", design="Wander", zoom=0.52)
            a.shot("Wander", 1280, 800, P("hero.png"))
            a.tool("select_layers", design="Wander", layers=["Trips grid"])
            a.tool("view", design="Wander", layer="Saved"); a.tool("view", design="Wander", zoom=0.76)
            a.press("Wander", 2, "1 × 5")
            a.shot("Wander", 1280, 800, P("grid.png"))
            a.tool("select_layers", design="Wander", layers=["Place/Book"])
            a.tool("view", design="Wander", layer="Place", zoom=0.8)
            a.press("Wander", 5, "Y 8")
            a.shot("Wander", 1280, 800, P("lea.png"))
            a.tool("select_layers", design="Ember & Oat", layers=["Headline"])
            a.tool("view", design="Ember & Oat", layer="Autumn menu", zoom=0.5)
            a.press("Ember & Oat", 2, "Bodoni")
            a.shot("Ember & Oat", 1280, 800, P("controls.png"))
            a.tool("select_layers", design="Ember & Oat", layers=["Autumn menu"])
            a.tool("view", design="Ember & Oat", layer="Autumn menu", zoom=0.44)
            a.shot("Ember & Oat", 1280, 800, P("deck.png"))
            a.tool("select_layers", design="Adoption Day", layers=["Pug"])
            a.tool("view", design="Adoption Day", layer="Poster", zoom=0.42)
            a.press("Adoption Day", 4)
            a.shot("Adoption Day", 1280, 800, P("cutout.png"))
            a.shot("Wander Pitch", 1280, 960, tmp, 0.2)
            a.tool("select_layers", design="Wander Pitch", layers=["Discover screen"])
            a.tool("view", design="Wander Pitch", layer="Discover screen", zoom=0.95)
            a.press("Wander Pitch", 5, "34°")
            a.shot("Wander Pitch", 1280, 960, P("depth.png"))
        else:
            a.tool("select_layers", design="Ember & Oat", layers=["Autumn menu"])
            a.tool("view", design="Ember & Oat", layer="Autumn menu", zoom=0.44)
            a.shot("Ember & Oat", 1280, 800, P("deck-dark.png"))
            a.tool("select_layers", design="Adoption Day", layers=["Pug"])
            a.tool("view", design="Adoption Day", layer="Poster", zoom=0.5)
            a.shot("Adoption Day", 1280, 800, P("cutout-dark.png"))
            a.tool("select_layers", design="Wander", layers=["Discover/Featured"])
            a.tool("view", design="Wander", zoom="fit"); a.tool("view", design="Wander", zoom=0.52)
            a.shot("Wander", 1280, 800, P("wander-dark.png"))
        a.quit()
    print("captured", LOCALES[lang])


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    app, langs = os.path.abspath(sys.argv[1]), sys.argv[2:] or ["en", "de", "fr", "it"]
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
            capture(app, lang, scratch)
    finally:
        display.terminate()
        subprocess.run(["defaults", "import", SUITE, backup])
