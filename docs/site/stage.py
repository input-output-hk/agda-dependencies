#!/usr/bin/env python3
"""Stage the repo's Markdown into Pelican's ``content/`` tree.

The canonical docs live at the repository root (README.md, Examples.md, …);
Pelican reads from ``content/``. Rather than duplicate the sources, this copies
each into ``content/pages/<slug>.md`` with a Pelican metadata header and its
cross-links rewritten to the rendered page names.

Run it before ``pelican`` — the Makefile's ``html`` target does exactly that.

    python3 stage.py                # public pages
    python3 stage.py --internal     # also stage AGENTS.md as "Internals"
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

from pelicanconf import DOC_PAGES, INTERNAL_PAGES  # single source of truth

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]                      # docs/site -> docs -> repo root
CONTENT = HERE / "content"
PAGES_DIR = CONTENT / "pages"

# Markdown link targets (README.md, …) that should point at the rendered page.
LINK_MAP = {p["src"]: p["out"] for p in DOC_PAGES + INTERNAL_PAGES}


def rewrite_links(md: str) -> str:
    """Point ``](README.md)`` / ``](Examples.md#anchor)`` at the built pages."""
    for src, out in LINK_MAP.items():
        md = re.sub(
            rf"\]\(\.?/?{re.escape(src)}(#[^)]*)?\)",
            lambda m, o=out: f"]({o}{m.group(1) or ''})",
            md,
        )
    return md


def stage_pages(pages: list[dict]) -> None:
    if PAGES_DIR.exists():
        shutil.rmtree(PAGES_DIR)
    PAGES_DIR.mkdir(parents=True, exist_ok=True)
    for p in pages:
        src = ROOT / p["src"]
        if not src.exists():
            sys.stderr.write(f"skip: {p['src']} not found\n")
            continue
        header = (
            f"Title: {p['title']}\n"
            f"slug: {p['slug']}\n"
            f"save_as: {p['out']}\n"
            f"url: {p['out']}\n"
            f"status: published\n"
            f"template: page\n\n"
        )
        body = rewrite_links(src.read_text(encoding="utf-8"))
        (PAGES_DIR / f"{p['slug']}.md").write_text(header + body, encoding="utf-8")
        print(f"  {p['src']:<14} -> content/pages/{p['slug']}.md")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Stage docs content for Pelican.")
    ap.add_argument("--internal", action="store_true",
                    help="Internals page")
    args = ap.parse_args(argv)

    pages = list(DOC_PAGES) + (list(INTERNAL_PAGES) if args.internal else [])
    print("Staging content/")
    stage_pages(pages)
    print("Done. Now run: pelican -s pelicanconf.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
