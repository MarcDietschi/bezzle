#!/usr/bin/env python3
"""Bezzle's release notes (RELEASE_NOTES.md): read, checked, and turned into what each place needs.

Usage: Scripts/release/notes.py STEP ...
  check <version>                  the entry for <version> is there, whole, in every language
  github <version>                 the GitHub release's text, in Markdown
  feed <in.xml> <out.xml> <version>
                                   the public update feed: the newest item of generate_appcast's
                                   feed alone, which must be <version>, with its notes in every
                                   language for Sparkle's update window

AppStore/site/build.py imports it for the website's What's New page.
"""
import html, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PATH = os.path.join(ROOT, "RELEASE_NOTES.md")
# English first: it is also the feed's description without a language, for every other Mac.
LANGS = ("en", "de", "fr", "it")
SITE = "https://mfrports.github.io/bezzle-web/"


def version_key(version):
    parts = [int(p) for p in version.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def parse(path=PATH):
    """Every release, newest first: {version, date, notes: {lang: {title, lede, items, after}}}."""
    text = re.sub(r"<!--.*?-->", "", open(path, encoding="utf-8").read(), flags=re.S)
    releases = []
    for block in re.split(r"^## ", text, flags=re.M)[1:]:
        head, _, body = block.partition("\n")
        m = re.fullmatch(r"(\d+(?:\.\d+){0,2}) · (\d{4}-\d{2}-\d{2})", head.strip())
        if not m:
            raise ValueError(f"A release heading should read '## <version> · <YYYY-MM-DD>', not '## {head.strip()}'")
        version, date = m.groups()
        notes = {}
        for part in re.split(r"^### ", body, flags=re.M)[1:]:
            head, _, rest = part.partition("\n")
            m = re.fullmatch(r"([a-z]{2}): (.+)", head.strip())
            if not m:
                raise ValueError(f"{version}: a language heading should read '### en: <Title.>', not '### {head.strip()}'")
            lang, title = m.groups()
            paragraphs = [" ".join(p.split()) for p in re.split(r"\n\s*\n", rest.strip()) if p.strip()]
            if not paragraphs:
                raise ValueError(f"{version} {lang}: no lede")
            items, after = [], []
            for p in paragraphs[1:]:
                if p.startswith("- "):
                    for line in re.split(r" (?=- \*\*)", p):
                        m = re.fullmatch(r"- \*\*(.+?)\*\* (.+)", line)
                        if not m:
                            raise ValueError(f"{version} {lang}: a highlight should read '- **Lead.** Text', not '{line[:60]}'")
                        items.append(m.groups())
                else:
                    after.append(p)
            notes[lang] = dict(title=title.strip(), lede=paragraphs[0], items=items, after=after)
        missing = [lang for lang in LANGS if lang not in notes]
        if missing:
            raise ValueError(f"{version}: no notes in {', '.join(missing)}")
        for lang, n in notes.items():
            if not n["title"].endswith("."):
                raise ValueError(f"{version} {lang}: the title should end with a full stop")
            for s in [n["title"], n["lede"], *[x for item in n["items"] for x in item], *n["after"]]:
                if "—" in s or re.search(r"\s[–-]\s", s):
                    raise ValueError(f"{version} {lang}: a dash as punctuation: {s[:60]}")
        releases.append(dict(version=version, date=date, notes=notes))
    return releases


def inline(s):
    return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", html.escape(s, quote=False))


def to_html(n, heading="h2"):
    out = [f"<{heading}>{inline(n['title'])}</{heading}>", f"<p>{inline(n['lede'])}</p>"]
    if n["items"]:
        out.append("<ul>" + "".join(f"<li><strong>{inline(a)}</strong> {inline(b)}</li>" for a, b in n["items"]) + "</ul>")
    out += [f"<p>{inline(p)}</p>" for p in n["after"]]
    return "\n".join(out)


def find(version, releases=None):
    for r in releases if releases is not None else parse():
        if r["version"] == version:
            return r
    raise SystemExit(f"RELEASE_NOTES.md has no entry for {version}: write it first (CLAUDE.md › Releases)")


def github(version):
    n = find(version)["notes"]["en"]
    lines = [f"**{n['title']}**", "", n["lede"], ""]
    lines += [f"- **{a}** {b}" for a, b in n["items"]]
    lines += ([""] if n["items"] else []) + [p + "\n" for p in n["after"]]
    lines += [f"In German, French and Italian: {SITE}releases.html"]
    return "\n".join(lines).replace("\n\n\n", "\n\n")


# Sparkle shows the notes in a small web view of its own; this keeps them in the system's type and colours.
STYLE = ("<style>:root{color-scheme:light dark}body{font:13px/1.45 -apple-system,sans-serif;margin:0 4px}"
         "h2{font-size:15px;margin:4px 0 6px}ul{padding-left:18px}li{margin:4px 0}</style>")


def feed(source, target, version):
    text = open(source, encoding="utf-8").read()
    items = list(re.finditer(r"[ \t]*<item>.*?</item>\s*", text, re.S))
    if not items:
        raise SystemExit(f"{source} lists no version")
    item = items[0].group(0)
    short = re.search(r"<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>", item)
    if not short or short.group(1) != version:
        raise SystemExit(f"The newest item of {source} is {short.group(1) if short else 'without a version'}, not {version}")
    notes = find(version)["notes"]
    # What generate_appcast may have put there gives way to the notes in every language. Sparkle
    # picks the description whose xml:lang fits the Mac, and the one without for every other.
    item = re.sub(r"\s*<description(?:\s[^>]*)?>.*?</description>", "", item, flags=re.S)
    descriptions = "".join(
        "\n            <description{}><![CDATA[{}]]></description>".format(
            "" if lang == "en" else f' xml:lang="{lang}"', (STYLE + to_html(notes[lang])).replace("]]>", "]]]]><![CDATA[>"))
        for lang in LANGS)
    item = re.sub(r"</title>", lambda m: m.group(0) + descriptions, item, count=1)
    text = text[:items[0].start()] + item + text[items[-1].end():]
    open(target, "w", encoding="utf-8").write(text)


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "check":
            find(argv[1])
        elif len(argv) == 2 and argv[0] == "github":
            print(github(argv[1]))
        elif len(argv) == 4 and argv[0] == "feed":
            feed(*argv[1:])
        else:
            raise SystemExit(__doc__)
    except ValueError as error:
        raise SystemExit(f"RELEASE_NOTES.md: {error}")


if __name__ == "__main__":
    main(sys.argv[1:])
