# agda-deps documentation site (Pelican)

The [`paper`](themes/paper) theme, rendered by [Pelican](https://getpelican.com).
It replaces the previous hand-rolled `build.py` generator: the same content and
look, split into the pieces a static-site generator expects.

The site is published into **`docs/`** (the parent of this folder) so GitHub
Pages can serve it directly from the repository's `docs/` directory.

## Build

```
make install      # once: create .venv and install pelican + markdown
make html         # stage content, then build into ../  (docs/)
make serve        # build, then serve docs/ on http://127.0.0.1:8000
make clean        # remove staged content + caches
```

`make html STAGE_FLAGS=--internal` also renders `CLAUDE.md` as an Internals page.

Without `make`:

```
.venv/bin/python stage.py
.venv/bin/pelican -s pelicanconf.py
```

## Layout

```
docs/                     Published site (GitHub Pages root):
  index.html …            generated pages
  theme/  views/          generated assets + copied view gallery
  .nojekyll               tells GitHub Pages to serve the files as-is
  site/                   this generator (retained across rebuilds):
    pelicanconf.py        Pelican config + the site content as data
                          (STATES / FORMATS / MODES / VIEW_HIGHLIGHTS / DOC_PAGES).
    stage.py              copies the repo-root Markdown into content/pages/ with
                          Pelican metadata + rewritten cross-links; mirrors views/.
    plugins/toc_sidebar.py builds the per-page sidebar TOC from heading ids.
    themes/paper/
      templates/base.html   page shell: top bar + footer.
      templates/index.html  the dashboard home page (reads the data tables).
      templates/page.html   doc pages: TOC sidebar + prose column.
      static/css/style.css  the stylesheet.
    content/              staged inputs (generated; git-ignored).
```

`make html` does a clean rebuild of `docs/` (`DELETE_OUTPUT_DIRECTORY`), but
`OUTPUT_RETENTION` keeps `docs/site` (this generator) and `docs/.nojekyll`.

## Where content comes from

There is no hidden source of truth. The doc pages are the project's own
Markdown at the repo root (`README.md`, `Examples.md`, `Changelog.md`,
`TODO.md`, `Backlog.md`); `stage.py` copies them in at build time. Edit the
Markdown — or the data tables in `pelicanconf.py` for the home page — and
re-run `make html`.

The `views/` gallery is copied verbatim as static files, so `--lazy` output
still needs an HTTP server (`make serve`).
