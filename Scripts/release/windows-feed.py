#!/usr/bin/env python3
"""The update feed of Bezzle for Windows (https://bezzle.ch/updates/windows/appcast.xml), which
WinSparkle in every installed copy reads, and the website's Windows download card shows.

Usage: Scripts/release/windows-feed.py <out.xml> <version> <build> <url-prefix> <arch>=<installer>=<edSignature> ...

One item, the newest version, as the Mac's feed lists its newest alone: its title, its date, the
build number updates are compared by (sparkle:version), the version people see, Windows 11 at the
least, the notes from RELEASE_NOTES.md in every language (notes.py reads them, as for the Mac's
feed), and one enclosure per architecture with its length and its EdDSA signature (Sparkle's
sign_update, with the key the Mac's updates are signed with). An update runs the installer quietly,
and the installer opens Bezzle again (Windows/Installer/Bezzle.iss).

WinSparkle shows an item's descriptions run together, whatever their xml:lang, so each holds its
notes in a block of its own language, and a line of script keeps only the block in the language
of the Windows it runs on (English where there is none, or where scripts do not run).
"""
import email.utils, html, importlib.util, os, re, sys

sys.dont_write_bytecode = True

# notes.py, beside this, read as the Mac's release reads it.
_spec = importlib.util.spec_from_file_location("notes", os.path.join(os.path.dirname(os.path.abspath(__file__)), "notes.py"))
notes = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(notes)

MINIMUM_WINDOWS = "10.0.22000"
# What an update runs the new installer with: no pages, a bar while it puts Bezzle in place, no
# questions, and Bezzle opened again after (/UPDATE=1).
INSTALLER_ARGUMENTS = "/SILENT /SP- /NOCANCEL /NORESTART /SUPPRESSMSGBOXES /UPDATE=1"
OS = {"x64": "windows-x64", "arm64": "windows-arm64"}

# In WinSparkle's window, which shows the notes in Edge's web view, in Windows' own type.
STYLE = ("<style>:root{color-scheme:light dark}body{font:13px/1.45 'Segoe UI',sans-serif;margin:0 4px}"
         "h2{font-size:15px;margin:4px 0 6px}ul{padding-left:18px}li{margin:4px 0}"
         ".notes{display:none}.notes:first-of-type{display:block}</style>")
# Keeps the notes in Windows' language (navigator.language follows it), when there are some.
PICK = ("<script>(function(){var n=document.querySelectorAll('.notes'),l=((navigator.languages&&navigator.languages[0])"
        "||navigator.language||navigator.userLanguage||'en').slice(0,2).toLowerCase(),p=null,i;"
        "for(i=0;i<n.length;i++)if(n[i].getAttribute('lang')==l)p=n[i];if(!p)return;"
        "for(i=0;i<n.length;i++)n[i].style.display=n[i]==p?'block':'none'})()</script>")


def cdata(s):
    return "<![CDATA[" + s.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def main(argv):
    if len(argv) < 5:
        raise SystemExit(__doc__)
    out, version, build, prefix, *enclosures = argv
    if not re.fullmatch(r"\d+(\.\d+){0,2}", version):
        raise SystemExit(f"A version reads like 1.4.2, not {version}")
    if not re.fullmatch(r"\d+(\.\d+)*", build) or any(int(p) > 2**31 - 1 for p in build.split(".")):
        # WinSparkle compares each part as a 32-bit number.
        raise SystemExit(f"A build reads like 20261108.1200, each part below 2^31, not {build}")
    try:
        written = notes.find(version)["notes"]
    except ValueError as error:
        raise SystemExit(f"RELEASE_NOTES.md: {error}")
    items = []
    for given in enclosures:
        arch, path, signature = given.split("=", 2)
        if arch not in OS:
            raise SystemExit(f"No architecture {arch}: x64 or arm64")
        name = f"Bezzle-{version}-Setup-{arch}.exe"
        if os.path.basename(path) != name:
            raise SystemExit(f"{path} should be named {name}")
        if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature):
            raise SystemExit(f"{signature} is not an EdDSA signature")
        items.append(f'            <enclosure url="{html.escape(prefix + name)}" length="{os.path.getsize(path)}" type="application/octet-stream"\n'
                     f'                sparkle:os="{OS[arch]}" sparkle:edSignature="{signature}"\n'
                     f'                sparkle:installerArguments="{INSTALLER_ARGUMENTS}"/>')
    if not items:
        raise SystemExit("No installer given")
    descriptions = "".join(
        "\n            <description{}>{}</description>".format(
            "" if lang == "en" else f' xml:lang="{lang}"',
            cdata(STYLE + f'<div class="notes" lang="{lang}">' + notes.to_html(written[lang]) + "</div>" + PICK))
        for lang in notes.LANGS)
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Bezzle for Windows</title>
        <link>https://bezzle.ch/</link>
        <language>en</language>
        <item>
            <title>Bezzle {version}</title>{descriptions}
            <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{MINIMUM_WINDOWS}</sparkle:minimumSystemVersion>
{chr(10).join(items)}
        </item>
    </channel>
</rss>
"""
    with open(out, "w", encoding="utf-8") as f:
        f.write(feed)


if __name__ == "__main__":
    main(sys.argv[1:])
