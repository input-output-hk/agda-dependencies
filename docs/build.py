#!/usr/bin/env python3
"""Render the agda-deps documentation site into ``docs/``.

The site is built entirely from the project's own Markdown files (README,
Examples, Changelog, …) plus the rendered HTML view gallery under ``views/``.
There is no hidden source of truth: edit the Markdown, re-run this script, and
the site is regenerated.

Usage::

    python3 docs/build.py            # build the public site into docs/
    python3 docs/build.py --internal # also render CLAUDE.md as "Internals"
    python3 docs/build.py --no-views # skip copying the views/ gallery
    python3 docs/build.py --serve    # build, then serve docs/ on :8000
    python3 docs/build.py clean      # remove every generated file from docs/

Markdown is rendered with ``pandoc`` when it is on ``PATH`` (best quality —
GFM tables, fenced code, heading anchors). A small dependency-free fallback
converter is used otherwise, so the script runs on a bare Python install.
"""

from __future__ import annotations

import argparse
import html as _html
import re
import shutil
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths & site-wide constants
# ---------------------------------------------------------------------------

DOCS = Path(__file__).resolve().parent
ROOT = DOCS.parent
ASSETS = DOCS / "assets"
VENDOR = DOCS / "vendor"            # committed third-party assets (PicoCSS); a source, not generated
VIEWS_SRC = ROOT / "views"
VIEWS_DST = DOCS / "views"

SITE_NAME = "agda-deps"
TAGLINE = "An Agda compiler backend that maps your proof's dependency graph."
GITHUB_URL = "https://github.com/input-output-hk/agda-dependencies"
GALLERY = "views/index.html"

# Markdown source -> output page. Order defines the "More docs" listing.
PAGES = [
    dict(src="README.md", out="guide.html", nav="Guide",
         title="User Guide",
         blurb="Install, flags, views, YAML config, and the v2 JSON schema."),
    dict(src="Examples.md", out="examples.html", nav="Examples",
         title="Examples",
         blurb="One runnable command per feature, with empirical defaults."),
    dict(src="Changelog.md", out="changelog.html", nav="Changelog",
         title="Changelog",
         blurb="Everything shipped, newest first."),
    dict(src="TODO.md", out="roadmap.html", nav="Roadmap",
         title="Roadmap",
         blurb="Forward-looking work that's actively planned."),
    dict(src="Backlog.md", out="backlog.html", nav="Backlog",
         title="Backlog",
         blurb="Ideas parked for later, plus approaches consciously set aside."),
]

# Rendered only with --internal: developer-facing architecture notes.
INTERNAL_PAGES = [
    dict(src="CLAUDE.md", out="internals.html", nav="Internals",
         title="Architecture & internals",
         blurb="Module map, backend pipeline, and hard-won gotchas."),
]

# Top-bar navigation (kept short; the rest live in the page footer).
TOP_NAV = [
    ("index.html", "Home"),
    ("guide.html", "Guide"),
    ("examples.html", "Examples"),
    (GALLERY, "Views ↗"),
    ("changelog.html", "Changelog"),
    (GITHUB_URL, "GitHub ↗"),
]

# Markdown link targets that should point at the rendered page instead.
LINK_MAP = {p["src"]: p["out"] for p in PAGES + INTERNAL_PAGES}

# ---------------------------------------------------------------------------
# Dashboard content (the "feature dashboard" on index.html)
# ---------------------------------------------------------------------------

STATES = [
    ("D", "Defined", "var(--d)", "Function, datatype, record — elaborated normally."),
    ("P", "Postulate", "var(--p)", "An axiom / postulate. A type-level promise, no body."),
    ("H", "Hole", "var(--h)", "Contains an unsolved meta (a <code>?</code> in source)."),
    ("F", "Failed", "var(--f)", "Module whose type-check failed under <code>--keep-going</code>."),
]

STATS = [
    ("3", "output formats"),
    ("14", "HTML views"),
    ("4", "node states"),
]

FORMATS = [
    ("DOT", "Graphviz", "A <code>.dot</code> graph you can pipe into Graphviz "
     "(<code>dot -Tsvg</code>) or any DOT-aware tool. The default format."),
    ("HTML", "Interactive", "A self-contained page in one of 14 views — from "
     "module DAGs to source-linked reading order. <code>--lazy</code> splits files "
     "for very large corpora."),
    ("JSON", "v2 graph.json", "A stable artifact for downstream tooling: "
     "<code>packed</code> (base64 CSR) or <code>expanded</code> (arrays of records) "
     "&mdash; a versioned wire contract consumers can pin to."),
]

# Each: (flag, one-line description)
MODES = [
    ("--keep-going", "Survive type-check errors; the failing module is tagged <code>F</code>."),
    ("--skip-agda", "Module-level graph straight from a source scan — no elaboration, milliseconds at any scale."),
    ("--with-source", "Attach the source snippet to every definition; powers the reading / IDE views."),
    ("--lazy", "Split HTML across files so 100k-node projects stay responsive (needs an HTTP server)."),
    ("--no-externals", "Drop everything outside the project root — stdlib and all — from the graph."),
    ("--resolve-deps", "Pin Agda's search path to the <code>.agda-lib</code> <code>depend:</code> closure."),
    ("--with-term-hashes", "Emit a canonicalised <code>Word64</code> fingerprint per definition subterm into the JSON."),
    ("--theme / --config", "Colour presets and a kebab-case YAML mirror of every CLI flag."),
]

# A curated slice of the view gallery for the dashboard preview grid.
VIEW_HIGHLIGHTS = [
    ("module-dag-pods", "Module DAG pods", "Default. Expandable module pods, dagre layout."),
    ("cytoscape", "Cytoscape compound", "Force-directed modules-as-boxes with a rich sidebar."),
    ("sigma", "Sigma (WebGL)", "WebGL renderer that scales to ~1M nodes."),
    ("progress-dashboard", "Progress dashboard", "KPI board: completeness %, hole debt, hot modules."),
    ("critical-path-holes", "Critical-path holes", "Kanban of proof obligations upstream of the goal."),
    ("sunburst-hierarchy", "Sunburst hierarchy", "D3 sunburst over the dotted-module tree."),
    ("source-centric", "Source-centric", "Code-first reading view with a minimap."),
    ("cartographic-atlas", "Cartographic atlas", "A topographic map of the whole project."),
]

# ===========================================================================
# Markdown -> HTML
# ===========================================================================

_HAVE_PANDOC: bool | None = None


def have_pandoc() -> bool:
    global _HAVE_PANDOC
    if _HAVE_PANDOC is None:
        _HAVE_PANDOC = shutil.which("pandoc") is not None
    return _HAVE_PANDOC


def md_to_html(text: str) -> str:
    """Render a Markdown document to an HTML fragment."""
    if have_pandoc():
        try:
            return subprocess.run(
                ["pandoc", "-f", "gfm", "-t", "html",
                 "--wrap=preserve", "--no-highlight"],
                input=text, capture_output=True, text=True, check=True,
            ).stdout
        except subprocess.CalledProcessError as exc:  # pragma: no cover
            sys.stderr.write(f"pandoc failed, using fallback: {exc}\n")
    return _fallback_md(text)


# --- dependency-free fallback converter ------------------------------------
# Not a full CommonMark implementation; it covers the constructs these docs
# actually use (headings, fenced code, pipe tables, nested lists, blockquotes,
# rules, inline code/emphasis/links). pandoc is strongly preferred.

def _slug(text: str) -> str:
    s = re.sub(r"<[^>]+>", "", text).strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return re.sub(r"\s+", "-", s)


def _inline(text: str) -> str:
    # Inline code first (protect its contents from further substitution).
    spans: list[str] = []

    def stash(m: re.Match) -> str:
        spans.append(f"<code>{_html.escape(m.group(1))}</code>")
        return f"\x00{len(spans) - 1}\x00"

    text = re.sub(r"`([^`]+)`", stash, text)
    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)",
                  r'<img alt="\1" src="\2">', text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], text)


def _fallback_md(text: str) -> str:  # noqa: C901  (intentionally linear)
    lines = text.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    i, n = 0, len(lines)
    list_stack: list[str] = []  # 'ul' / 'ol'

    def close_lists(to: int = 0) -> None:
        while len(list_stack) > to:
            out.append(f"</li></{list_stack.pop()}>")

    while i < n:
        line = lines[i]

        m = re.match(r"^```(.*)$", line)
        if m:
            close_lists()
            buf = []
            i += 1
            while i < n and not lines[i].startswith("```"):
                buf.append(_html.escape(lines[i]))
                i += 1
            i += 1
            out.append("<pre><code>" + "\n".join(buf) + "</code></pre>")
            continue

        if re.match(r"^\s*$", line):
            close_lists()
            i += 1
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            close_lists()
            lvl = len(m.group(1))
            body = _inline(m.group(2))
            out.append(f'<h{lvl} id="{_slug(m.group(2))}">{body}</h{lvl}>')
            i += 1
            continue

        if re.match(r"^(\s*)([-*_])(\s*\2){2,}\s*$", line):
            close_lists()
            out.append("<hr>")
            i += 1
            continue

        # GitHub pipe table: header row, separator, body rows.
        if "|" in line and i + 1 < n and re.match(r"^\s*\|?[\s:|-]+\|?\s*$", lines[i + 1]):
            close_lists()

            def cells(row: str) -> list[str]:
                row = row.strip().strip("|")
                return [c.strip() for c in row.split("|")]

            head = cells(line)
            out.append("<table><thead><tr>"
                       + "".join(f"<th>{_inline(c)}</th>" for c in head)
                       + "</tr></thead><tbody>")
            i += 2
            while i < n and "|" in lines[i] and lines[i].strip():
                out.append("<tr>" + "".join(
                    f"<td>{_inline(c)}</td>" for c in cells(lines[i])) + "</tr>")
                i += 1
            out.append("</tbody></table>")
            continue

        m = re.match(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$", line)
        if m:
            depth = len(m.group(1)) // 2 + 1
            kind = "ol" if m.group(2)[0].isdigit() else "ul"
            while len(list_stack) < depth:
                out.append(f"<{kind}>")
                list_stack.append(kind)
            while len(list_stack) > depth:
                out.append(f"</li></{list_stack.pop()}>")
            if out and out[-1].startswith(("<ul", "<ol")):
                out.append(f"<li>{_inline(m.group(3))}")
            else:
                out.append(f"</li><li>{_inline(m.group(3))}")
            i += 1
            continue

        if line.startswith(">"):
            close_lists()
            buf = []
            while i < n and lines[i].startswith(">"):
                buf.append(_inline(lines[i].lstrip("> ").rstrip()))
                i += 1
            out.append("<blockquote>" + "<br>".join(buf) + "</blockquote>")
            continue

        close_lists()
        para = [line]
        i += 1
        while i < n and lines[i].strip() and not re.match(
                r"^(#{1,6}\s|```|>|\s*[-*+]\s|\s*\d+[.)]\s)", lines[i]):
            para.append(lines[i])
            i += 1
        out.append("<p>" + _inline(" ".join(para)) + "</p>")

    close_lists()
    return "\n".join(out)


# ===========================================================================
# Post-processing: link rewriting + TOC extraction
# ===========================================================================

def rewrite_links(body: str) -> str:
    """Point Markdown cross-references at the rendered HTML pages."""
    for src, dst in LINK_MAP.items():
        # href="README.md", href="./README.md", with optional #anchor
        body = re.sub(
            rf'href="\.?/?{re.escape(src)}(#[^"]*)?"',
            lambda m, d=dst: f'href="{d}{m.group(1) or ""}"',
            body,
        )
    return body


def extract_toc(body: str) -> list[tuple[int, str, str]]:
    toc = []
    for m in re.finditer(r'<h([23])\s+id="([^"]+)">(.*?)</h\1>', body, re.S):
        label = re.sub(r"<[^>]+>", "", m.group(3)).strip()
        toc.append((int(m.group(1)), m.group(2), label))
    return toc


# ===========================================================================
# HTML templates
# ===========================================================================

def nav_html(active: str) -> str:
    items = []
    for href, label in TOP_NAV:
        cls = ' class="active"' if href == active else ""
        items.append(f'<a href="{href}"{cls}>{label}</a>')
    return (
        '<header class="topbar"><div class="bar">'
        f'<a class="brand" href="index.html">{SITE_NAME}</a>'
        '<nav>' + "".join(items) + '</nav>'
        '</div></header>'
    )


def footer_html() -> str:
    links = " · ".join(
        f'<a href="{p["out"]}">{p["nav"]}</a>' for p in PAGES
    )
    return (
        '<footer class="site-footer"><div class="wrap">'
        f'<div>{links}</div>'
        f'<div class="muted">Built from the repository’s Markdown by '
        f'<code>docs/build.py</code>. '
        f'<a href="{GITHUB_URL}">Source on GitHub ↗</a></div>'
        '</div></footer>'
    )


def page_shell(title: str, active: str, content: str, *,
               toc: list[tuple[int, str, str]] | None = None,
               wide: bool = False) -> str:
    toc_html = ""
    if toc:
        items = "".join(
            f'<a class="lvl{lvl}" href="#{anchor}">{_html.escape(text)}</a>'
            for lvl, anchor, text in toc
        )
        toc_html = (
            '<aside class="toc"><div class="toc-inner">'
            '<div class="toc-title">On this page</div>'
            f'<nav>{items}</nav></div></aside>'
        )
    layout_cls = "layout wide" if wide else "layout"
    main = (
        f'<div class="{layout_cls}">{toc_html}'
        f'<div class="prose">{content}</div></div>'
        if not wide else f'<div class="{layout_cls}">{content}</div>'
    )
    return f"""<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_html.escape(title)} · {SITE_NAME}</title>
<link rel="stylesheet" href="assets/pico.min.css">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>
{nav_html(active)}
<main>{main}</main>
{footer_html()}
</body>
</html>
"""


# ===========================================================================
# Dashboard (index.html)
# ===========================================================================

def dashboard_html() -> str:
    legend = "".join(
        f'<span><i class="dot" style="background:{c}"></i>{name}</span>'
        for _, name, c, _ in STATES
    )

    stats = "".join(
        f'<div class="stat"><div class="num">{n}</div>'
        f'<div class="lbl">{l}</div></div>'
        for n, l in STATS
    )

    state_cards = "".join(
        f'<div class="state-card" style="--c:{c}">'
        f'<div class="badge">{code}</div>'
        f'<div><strong>{name}</strong><p>{desc}</p></div></div>'
        for code, name, c, desc in STATES
    )

    fmt_cards = "".join(
        f'<div class="card"><div class="card-tag">{tag}</div>'
        f'<h3>{name}</h3><p>{desc}</p></div>'
        for name, tag, desc in FORMATS
    )

    mode_rows = "".join(
        f'<div class="mode"><code>{flag}</code><span>{desc}</span></div>'
        for flag, desc in MODES
    )

    view_cards = "".join(
        f'<a class="view-card" href="views/{slug}/deps.html">'
        f'<span class="vframe"><iframe src="views/{slug}/deps.html" '
        f'loading="lazy" scrolling="no" title="{name}"></iframe>'
        f'<span class="open">Open ↗</span></span>'
        f'<span class="vmeta"><strong>{name}</strong>'
        f'<code>--view={slug}</code><em>{desc}</em></span></a>'
        for slug, name, desc in VIEW_HIGHLIGHTS
    )

    doc_cards = "".join(
        f'<a class="doc-card" href="{p["out"]}">'
        f'<strong>{p["nav"]}</strong><span>{p["blurb"]}</span></a>'
        for p in PAGES
    )

    content = f"""
<section class="hero">
  <div class="wrap">
    <h1>{SITE_NAME}</h1>
    <p class="tag">{TAGLINE}</p>
    <p class="lede">A backend for the Agda compiler. It runs inside the
      type-checker and emits a graph of how every definition, postulate, and
      unfinished lemma depends on the others &mdash; as Graphviz DOT, an
      interactive HTML view, or stable JSON for downstream tooling.</p>
    <div class="cta">
      <a class="btn primary" href="guide.html">Read the guide</a>
      <a class="btn" href="{GALLERY}">Browse the views ↗</a>
      <a class="btn" href="examples.html">Examples</a>
    </div>
    <pre class="hero-cmd"><code>cabal run agda-deps -- --format=html --view=module-dag-pods \\
  --with-source -i test/ -o out/ test/Test.agda</code></pre>
    <div class="legend"><strong>Node state:</strong>{legend}</div>
  </div>
</section>

<section class="strip"><div class="wrap stats">{stats}</div></section>

<section class="block"><div class="wrap">
  <h2>Four states, one colour each</h2>
  <p class="block-lede">Every node in the graph is one of four states. The
    whole tool is built around making the unfinished ones (holes, postulates,
    failed modules) easy to find and reason about.</p>
  <div class="state-grid">{state_cards}</div>
</div></section>

<section class="block alt"><div class="wrap">
  <h2>Three output formats</h2>
  <div class="cards three">{fmt_cards}</div>
</div></section>

<section class="block"><div class="wrap">
  <h2>Modes &amp; flags worth knowing</h2>
  <div class="modes">{mode_rows}</div>
  <p class="more"><a href="guide.html#backend-flags">Full flag reference in the guide →</a></p>
</div></section>

<section class="block alt"><div class="wrap">
  <h2>The views</h2>
  <p class="block-lede">14 HTML views, each answering a different question.
    Below is a live slice &mdash; click any to open it, or see the
    <a href="{GALLERY}">full gallery</a>.</p>
  <div class="view-grid">{view_cards}</div>
</div></section>

<section class="block"><div class="wrap">
  <h2>Documentation</h2>
  <div class="doc-grid">{doc_cards}</div>
</div></section>
"""
    return page_shell("Documentation", "index.html", content, wide=True)


# ===========================================================================
# Build
# ===========================================================================

def build_page(page: dict) -> None:
    src = ROOT / page["src"]
    if not src.exists():
        sys.stderr.write(f"skip: {page['src']} not found\n")
        return
    body = rewrite_links(md_to_html(src.read_text(encoding="utf-8")))
    toc = extract_toc(body)
    # The first <h1> becomes the page title; drop it from the body so the
    # layout's own heading style governs.
    out = page_shell(page["title"], page["out"], body, toc=toc)
    (DOCS / page["out"]).write_text(out, encoding="utf-8")
    print(f"  {page['src']:<14} -> docs/{page['out']}")


def copy_views() -> None:
    if not VIEWS_SRC.exists():
        sys.stderr.write("note: views/ not found; skipping gallery copy\n")
        return
    if VIEWS_DST.exists():
        shutil.rmtree(VIEWS_DST)
    shutil.copytree(VIEWS_SRC, VIEWS_DST)
    n = sum(1 for _ in VIEWS_DST.rglob("*.html"))
    print(f"  views/         -> docs/views/  ({n} html files)")


def write_css() -> None:
    (ASSETS).mkdir(parents=True, exist_ok=True)
    (ASSETS / "style.css").write_text(CSS, encoding="utf-8")
    print("  style.css      -> docs/assets/style.css")
    pico = VENDOR / "pico.min.css"
    if pico.exists():
        shutil.copy(pico, ASSETS / "pico.min.css")
        print("  pico.min.css   -> docs/assets/pico.min.css")
    else:
        sys.stderr.write("warning: vendor/pico.min.css missing; pages will be "
                         "unstyled until it is restored\n")


def clean() -> int:
    """Remove everything the build emits, leaving only the sources.

    The set of artifacts is derived from the same tables the build uses
    (``PAGES`` / ``INTERNAL_PAGES``), so it stays in sync automatically.
    ``build.py`` and ``README.md`` are the only files that survive.
    """
    removed = 0

    # Rendered Markdown pages (public + internal) and the dashboard.
    html_files = [p["out"] for p in PAGES + INTERNAL_PAGES] + ["index.html"]
    for name in sorted(set(html_files)):
        f = DOCS / name
        if f.exists():
            f.unlink()
            print(f"  removed docs/{name}")
            removed += 1

    # Generated directories: the views gallery, the assets dir (style.css),
    # and Python's bytecode cache for this script.
    for d in (VIEWS_DST, ASSETS, DOCS / "__pycache__"):
        if d.exists():
            shutil.rmtree(d)
            print(f"  removed docs/{d.name}/")
            removed += 1

    print(f"Done. Removed {removed} item(s)." if removed
          else "Nothing to clean.")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Build the agda-deps docs site.")
    ap.add_argument("command", nargs="?", default="build",
                    choices=["build", "clean"],
                    help="build (default) the site, or clean removes every "
                         "generated file from docs/")
    ap.add_argument("--internal", action="store_true",
                    help="also render CLAUDE.md as an Internals page")
    ap.add_argument("--no-views", action="store_true",
                    help="do not copy the views/ gallery into docs/")
    ap.add_argument("--serve", action="store_true",
                    help="serve docs/ on http://localhost:8000 after building")
    args = ap.parse_args(argv)

    if args.command == "clean":
        print("Cleaning docs/")
        return clean()

    renderer = "pandoc" if have_pandoc() else "built-in fallback"
    print(f"Rendering docs/ (markdown via {renderer})")

    write_css()
    pages = PAGES + (INTERNAL_PAGES if args.internal else [])
    for page in pages:
        build_page(page)

    (DOCS / "index.html").write_text(dashboard_html(), encoding="utf-8")
    print("  (dashboard)    -> docs/index.html")

    if not args.no_views:
        copy_views()

    print("Done. Open docs/index.html")

    if args.serve:
        import http.server
        import os
        os.chdir(DOCS)
        print("Serving on http://localhost:8000  (Ctrl-C to stop)")
        http.server.test(HandlerClass=http.server.SimpleHTTPRequestHandler,
                         port=8000, bind="127.0.0.1")
    return 0


# ===========================================================================
# Stylesheet (single source; written to docs/assets/style.css)
# ===========================================================================

CSS = """\
/* agda-deps docs — a thin layer over PicoCSS v2 (loaded first, dark theme).
   Pico supplies typography, colours, links, code, tables and spacing; this
   file adds only what the framework doesn't: the top bar, hero, card grids,
   TOC sidebar and view gallery, plus the four tool-state colours. */
:root{ --d:#4caf50; --p:#f44336; --h:#9c27b0; --f:#ff9800; --maxw:1180px; }
[data-theme="dark"]{
  --pico-primary:#5b9dff;
  --pico-primary-hover:#83b6ff;
  --pico-primary-focus:rgba(91,157,255,.25);
  --pico-border-radius:10px;
}
body{margin:0}
.topbar,main,.site-footer{padding:0}
main{min-height:60vh}
main section{margin:0}
.wrap{max-width:var(--maxw);margin:0 auto;padding:0 28px}
.muted{color:var(--pico-muted-color)}

/* top bar */
.topbar{position:sticky;top:0;z-index:20;background:var(--pico-background-color);
  border-bottom:1px solid var(--pico-muted-border-color)}
.topbar .bar{max-width:var(--maxw);margin:0 auto;padding:0 28px;height:56px;
  display:flex;align-items:center;gap:22px}
.brand{font-weight:700;font-size:16px;color:var(--pico-color);text-decoration:none}
.brand:hover{color:var(--pico-primary)}
.topbar nav{display:flex;gap:18px;flex-wrap:wrap;margin-left:auto;font-size:14px}
.topbar nav a{color:var(--pico-muted-color);text-decoration:none}
.topbar nav a:hover,.topbar nav a.active{color:var(--pico-color)}

/* hero */
.hero{padding:64px 0 36px;border-bottom:1px solid var(--pico-muted-border-color)}
.hero h1{font-size:46px;margin:0;letter-spacing:-.02em}
.hero .tag{font-size:19px;margin:.4em 0 0;font-weight:500}
.hero .lede{max-width:720px;color:var(--pico-muted-color)}
.cta{display:flex;gap:12px;flex-wrap:wrap;margin:22px 0 26px}
.btn{display:inline-block;padding:10px 18px;border-radius:var(--pico-border-radius);
  font-weight:600;font-size:14px;text-decoration:none;color:var(--pico-color);
  background:var(--pico-card-background-color);border:1px solid var(--pico-muted-border-color)}
.btn:hover{border-color:var(--pico-primary)}
.btn.primary{background:var(--pico-primary);color:#06101f;border-color:var(--pico-primary)}
.hero-cmd{max-width:760px;font-size:12.5px;margin-top:0}
.hero-cmd code{white-space:pre}
.legend{display:flex;gap:18px;flex-wrap:wrap;margin-top:22px;font-size:13px;color:var(--pico-muted-color)}
.legend span{display:inline-flex;align-items:center;gap:7px}
.dot{width:11px;height:11px;border-radius:3px;display:inline-block}

/* stats strip */
.strip{background:var(--pico-card-background-color);
  border-top:1px solid var(--pico-muted-border-color);
  border-bottom:1px solid var(--pico-muted-border-color)}
.stats{display:flex;gap:8px;flex-wrap:wrap;padding:22px 28px;justify-content:space-between}
.stat{text-align:center;flex:1;min-width:110px}
.stat .num{font-size:34px;font-weight:750;letter-spacing:-.02em}
.stat .lbl{color:var(--pico-muted-color);font-size:13px;text-transform:uppercase;letter-spacing:.06em}

/* content blocks */
.block{padding:48px 0}
.block.alt{background:var(--pico-card-background-color);
  border-top:1px solid var(--pico-muted-border-color);
  border-bottom:1px solid var(--pico-muted-border-color)}
.block h2{font-size:25px;margin:0 0 6px;letter-spacing:-.01em}
.block-lede{color:var(--pico-muted-color);max-width:760px;margin:0 0 24px}
.more{margin-top:18px}

/* cards & grids */
.state-grid{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(240px,1fr))}
.state-card{display:flex;gap:14px;align-items:flex-start;background:var(--pico-card-background-color);
  border:1px solid var(--pico-muted-border-color);border-left:4px solid var(--c);
  border-radius:12px;padding:16px}
.state-card .badge{width:30px;height:30px;border-radius:8px;background:var(--c);color:#0b0d12;
  font-weight:800;display:flex;align-items:center;justify-content:center;flex:none}
.state-card p{margin:.3em 0 0;color:var(--pico-muted-color);font-size:13.5px}
.cards{display:grid;gap:18px}
.cards.three{grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}
.cards.two{grid-template-columns:repeat(auto-fit,minmax(320px,1fr))}
.card{background:var(--pico-card-background-color);border:1px solid var(--pico-muted-border-color);
  border-radius:13px;padding:20px}
.card h3{margin:0 0 4px;font-size:18px}
.card.exe h3 code{font-size:17px}
.card-tag{display:inline-block;font-size:11px;text-transform:uppercase;letter-spacing:.06em;
  color:var(--pico-primary);font-weight:700;margin-bottom:8px}
.card p{margin:0;color:var(--pico-muted-color);font-size:14px}
.pill{font-size:10px;text-transform:uppercase;letter-spacing:.05em;color:var(--f);
  background:rgba(255,152,0,.12);border:1px solid rgba(255,152,0,.42);border-radius:999px;
  padding:2px 8px;vertical-align:middle}
.modes{display:grid;gap:10px;grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
.mode{display:flex;gap:12px;align-items:baseline;background:var(--pico-card-background-color);
  border:1px solid var(--pico-muted-border-color);border-radius:10px;padding:11px 14px}
.mode code{color:var(--pico-primary);font-size:13px;font-weight:600;white-space:nowrap;flex:none}
.mode span{color:var(--pico-muted-color);font-size:13.5px}
.an-group{margin-bottom:22px}
.an-title{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--pico-muted-color);
  font-weight:700;margin:0 0 10px}
.an-grid{display:grid;gap:10px;grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}
.an{background:var(--pico-card-background-color);border:1px solid var(--pico-muted-border-color);
  border-radius:10px;padding:11px 14px}
.an code{color:var(--pico-primary);font-weight:700;font-size:13.5px;display:block;margin-bottom:2px}
.an span{color:var(--pico-muted-color);font-size:13px}

/* view gallery */
.view-grid{display:grid;gap:16px;grid-template-columns:repeat(auto-fill,minmax(270px,1fr))}
.view-card{display:flex;flex-direction:column;background:var(--pico-card-background-color);
  border:1px solid var(--pico-muted-border-color);border-radius:13px;overflow:hidden;
  color:inherit;text-decoration:none}
.view-card:hover{border-color:var(--pico-primary);transform:translateY(-2px);transition:.15s}
.vframe{display:block;position:relative;height:150px;
  background:var(--pico-card-sectioning-background-color);
  border-bottom:1px solid var(--pico-muted-border-color);overflow:hidden}
.vframe iframe{width:200%;height:300px;border:0;transform:scale(.5);transform-origin:top left;
  pointer-events:none;background:#fff}
.vframe .open{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
  color:#fff;font-weight:650;opacity:0;background:rgba(0,0,0,.5);transition:.15s}
.view-card:hover .open{opacity:1}
.vmeta{padding:13px 15px;display:flex;flex-direction:column;gap:3px}
.vmeta strong{font-size:15px}
.vmeta code{font-size:11.5px;color:var(--pico-primary)}
.vmeta em{font-style:normal;color:var(--pico-muted-color);font-size:12.5px}
.doc-grid{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(250px,1fr))}
.doc-card{display:flex;flex-direction:column;gap:5px;background:var(--pico-card-background-color);
  border:1px solid var(--pico-muted-border-color);border-radius:12px;padding:18px;
  color:inherit;text-decoration:none}
.doc-card:hover{border-color:var(--pico-primary)}
.doc-card strong{font-size:16px}
.doc-card span{color:var(--pico-muted-color);font-size:13.5px}

/* doc pages: TOC sidebar + prose */
.layout{max-width:var(--maxw);margin:0 auto;padding:8px 28px 40px;
  display:grid;grid-template-columns:240px minmax(0,1fr);gap:38px;align-items:start}
.layout.wide{display:block;padding:0}
.toc{position:sticky;top:72px;align-self:start;max-height:calc(100vh - 90px);overflow:auto}
.toc-inner{border-left:1px solid var(--pico-muted-border-color);padding:4px 0}
.toc-title{font-size:11px;text-transform:uppercase;letter-spacing:.08em;
  color:var(--pico-muted-color);font-weight:700;padding:6px 0 8px 16px}
.toc nav{display:flex;flex-direction:column}
.toc nav a{color:var(--pico-muted-color);font-size:13px;padding:4px 0 4px 16px;
  border-left:2px solid transparent;margin-left:-1px;text-decoration:none}
.toc nav a:hover{color:var(--pico-color);border-left-color:var(--pico-primary)}
.toc nav a.lvl3{padding-left:30px;font-size:12.5px}
.prose{min-width:0;padding-top:14px}
.prose h1{font-size:33px;letter-spacing:-.02em;line-height:1.2;margin:.2em 0 .5em}
.prose h2{font-size:24px;margin:1.8em 0 .5em;padding-top:1em;
  border-top:1px solid var(--pico-muted-border-color)}
.prose h3{font-size:19px;margin:1.5em 0 .4em}
.prose h1[id],.prose h2[id],.prose h3[id]{scroll-margin-top:72px}
.prose pre{font-size:12.8px}
.prose table{display:block;overflow-x:auto}

/* footer */
.site-footer{border-top:1px solid var(--pico-muted-border-color);
  background:var(--pico-card-background-color);margin-top:40px}
.site-footer .wrap{padding:26px 28px;display:flex;justify-content:space-between;gap:18px;
  flex-wrap:wrap;font-size:13px}
.site-footer a{color:var(--pico-muted-color);text-decoration:none}
.site-footer a:hover{color:var(--pico-color)}

@media (max-width:820px){
  .layout{grid-template-columns:1fr}
  .toc{display:none}
  .hero h1{font-size:36px}
  .topbar nav{gap:12px}
}
"""


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
