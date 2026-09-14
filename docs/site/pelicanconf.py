#!/usr/bin/env python3
"""Pelican configuration for the agda-deps documentation site.

The site is built from the project's own Markdown (README, Examples, Changelog,
…), staged into ``content/`` by ``stage.py``, and rendered with the ``paper``
theme under ``themes/paper``. The page-level content lives here as plain data
(``STATES`` / ``FORMATS`` / ``MODES`` / ``CONSUMERS`` / ``DOC_PAGES``);
the templates iterate over it.

Every ALL-CAPS name in this file is copied into the Jinja template context by
Pelican, so the theme reads these tables directly.
"""

import os

# Absolute anchors so the build works regardless of the current directory.
_HERE = os.path.dirname(os.path.abspath(__file__))   # docs/site

# --- site identity ---------------------------------------------------------

SITENAME = "agda-deps"
SITE_TAGLINE = "An Agda dependency graph generator."
GITHUB_URL = "https://github.com/input-output-hk/agda-dependencies"
PLOTTER_URL = "https://github.com/input-output-hk/agda-plotter"
EXPLORER_URL = "https://github.com/input-output-hk/agda-graph-explorer"

SITEURL = ""
PATH = os.path.join(_HERE, "content")
# Publish straight into docs/ (the parent) so GitHub Pages can serve it.
OUTPUT_PATH = os.path.abspath(os.path.join(_HERE, os.pardir))
THEME = os.path.join(_HERE, "themes", "paper")
TIMEZONE = "UTC"
DEFAULT_LANG = "en"

# --- content layout --------------------------------------------------------
# Pages come from content/pages; there are no blog articles, so point
# ARTICLE_PATHS at an empty dir and stage no static assets of our own.

PAGE_PATHS = ["pages"]
ARTICLE_PATHS = ["articles"]          # intentionally empty (no blog)
STATIC_PATHS = []
PAGE_URL = "{slug}.html"
PAGE_SAVE_AS = "{slug}.html"

# The home page is a direct template (the dashboard), not an article index.
DIRECT_TEMPLATES = ["index"]
INDEX_SAVE_AS = "index.html"

# Turn off everything blog-shaped: feeds, tags, categories, authors, archives.
FEED_ALL_ATOM = None
CATEGORY_FEED_ATOM = None
TRANSLATION_FEED_ATOM = None
AUTHOR_FEED_ATOM = None
AUTHOR_FEED_RSS = None
TAG_SAVE_AS = ""
CATEGORY_SAVE_AS = ""
AUTHOR_SAVE_AS = ""
TAGS_SAVE_AS = ""
CATEGORIES_SAVE_AS = ""
AUTHORS_SAVE_AS = ""
ARCHIVES_SAVE_AS = ""
DEFAULT_PAGINATION = False
RELATIVE_URLS = False
# Clean rebuild into docs/, but never delete the generator or the Pages marker
# that live alongside the output.
DELETE_OUTPUT_DIRECTORY = True
OUTPUT_RETENTION = ["site", ".nojekyll"]

# --- markdown --------------------------------------------------------------
# toc: adds stable heading ids (consumed by the sidebar-TOC plugin) and pipe
# tables + fenced code, matching the GFM the docs are written in. No syntax
# highlighting, keeping code blocks plain (the paper look).

MARKDOWN = {
    "extension_configs": {
        "markdown.extensions.toc": {"permalink": False},
        "markdown.extensions.tables": {},
        "markdown.extensions.fenced_code": {},
    },
    "output_format": "html5",
}

JINJA_ENVIRONMENT = {"trim_blocks": True, "lstrip_blocks": True}

# --- local plugin: sidebar table of contents -------------------------------

PLUGIN_PATHS = [os.path.join(_HERE, "plugins")]
PLUGINS = ["toc_sidebar"]

# ===========================================================================
# Site content — the data the templates render. stage.py imports DOC_PAGES /
# INTERNAL_PAGES from here, so this stays the one source of truth for "which
# Markdown file maps to which page".
# ===========================================================================

# Top-bar navigation (kept short; the rest live in the footer).
TOP_NAV = [
    ("index.html", "Home"),
    ("guide.html", "Guide"),
    ("examples.html", "Examples"),
    # ("changelog.html", "Changelog"),
    (GITHUB_URL, "GitHub ↗"),
]

# (code, name, description) — the four node states. Colour comes from the
# .m-<code> CSS class, so it is not repeated here.
STATES = [
    ("D", "Defined", "Function, datatype, record, constructor — elaborated normally."),
    ("P", "Postulate", "An axiom / postulate. A type-level promise, no body."),
    ("H", "Hole", "Contains an unsolved meta (a <code>?</code> in source)."),
    ("F", "Failed", "Module whose type-check failed under <code>--keep-going</code>."),
]

# (name, description)
FORMATS = [
    ("DOT", "A <code>.dot</code> graph you can pipe into Graphviz "
     "(<code>dot -Tsvg</code>) or any DOT-aware tool. The default format."),
    ("JSON", "A stable artifact for downstream tooling: <code>packed</code> "
     "(base64 CSR) or <code>expanded</code> (arrays of records) &mdash; a "
     "versioned wire contract consumers can pin to."),
]

# (name, url, description) — the tools that read the JSON. Neither links Agda.
CONSUMERS = [
    ("agda-plotter", PLOTTER_URL,
     "Renders the graph as an interactive HTML page — 14 views, from module "
     "DAGs to definition-level browsing. <code>--lazy</code> keeps the page "
     "small on very large corpora."),
    ("agda-graph-explorer", EXPLORER_URL,
     "Unused-import and dead-code analysis, 18 graph-level analyses, and an "
     "MCP server that answers point queries for coding agents."),
]

# (flag, description)
MODES = [
    ("--keep-going", "Survive type-check errors; the failing module is tagged <code>F</code>."),
    ("--skip-agda", "Module-level graph straight from a source scan — no elaboration, milliseconds at any scale."),
    ("--lazy", "Split the JSON into a module skeleton plus per-module detail files, so 100k-node projects stay responsive."),
    ("--no-externals", "Drop everything outside the project root — stdlib and all — from the graph."),
    ("--resolve-deps", "Pin Agda's search path to the <code>.agda-lib</code> <code>depend:</code> closure."),
    ("--with-term-hashes", "Emit a canonicalised <code>Word64</code> fingerprint per definition subterm into the JSON."),
    ("--theme / --config", "Colour presets and a kebab-case YAML mirror of every CLI flag."),
]

# Markdown source -> rendered page. Order defines the footer + "Documentation"
# listing. stage.py reads src/slug/out/title; the templates read out/nav/blurb.
DOC_PAGES = [
    dict(src="README.md", out="guide.html", slug="guide", nav="Guide",
         title="User Guide",
         blurb="Install, flags, YAML config, and the v2 JSON schema."),
    dict(src="Examples.md", out="examples.html", slug="examples", nav="Examples",
         title="Examples",
         blurb="One runnable command per feature."),
    dict(src="TODO.md", out="roadmap.html", slug="roadmap", nav="Roadmap",
         title="Roadmap",
         blurb="Forward-looking work that's actively planned."),
    dict(src="Backlog.md", out="backlog.html", slug="backlog", nav="Backlog",
         title="Backlog",
         blurb="Ideas parked for later, plus approaches consciously set aside."),
    dict(src="Changelog.md", out="changelog.html", slug="changelog", nav="Changelog",
         title="Changelog",
         blurb="Everything shipped, newest first."),
]

# Staged only with `stage.py --internal`. These are not published: a plain
# `make html` must still rebuild every page under docs/, or a committed page
# goes stale while the rest of the site moves on.
INTERNAL_PAGES = [
    dict(src="AGENTS.md", out="internals.html", slug="internals", nav="Internals",
         title="Contributor guide",
         blurb="Repository map, validation workflow, and change invariants."),
]
