"""Sidebar table of contents for doc pages.

The Markdown ``toc`` extension already stamps a stable ``id`` onto every
heading. This plugin harvests the ``<h2>`` / ``<h3>`` ids straight from the
rendered HTML (so the anchors are guaranteed to match) and attaches a flat
``page.toc_sidebar`` fragment — ``<a class="lvl2">`` / ``<a class="lvl3">`` —
which ``page.html`` drops into the sidebar. Reading the ids from the output,
rather than re-deriving slugs, keeps producer and consumer in lockstep.
"""

from __future__ import annotations

import re

from pelican import signals

_HEADING = re.compile(r'<h([23])[^>]*\bid="([^"]+)"[^>]*>(.*?)</h\1>', re.S)
_TAGS = re.compile(r"<[^>]+>")


def _attach_toc(content) -> None:
    html = getattr(content, "_content", None)
    if not html:
        return
    items = []
    for m in _HEADING.finditer(html):
        level = m.group(1)
        anchor = m.group(2)
        label = _TAGS.sub("", m.group(3)).strip()
        items.append(f'<a class="lvl{level}" href="#{anchor}">{label}</a>')
    content.toc_sidebar = "".join(items)


def register() -> None:
    signals.content_object_init.connect(_attach_toc)
