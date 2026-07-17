# Documentation site

This folder holds a static documentation site for `agda-deps`, generated
from the repository's own Markdown files plus the rendered HTML view gallery.

## Build

```sh
python3 docs/build.py            # render the public site into docs/
python3 docs/build.py --serve    # build, then serve docs/ on http://localhost:8000
python3 docs/build.py --internal # also include CLAUDE.md as an "Internals" page
python3 docs/build.py --no-views # skip copying the views/ gallery
```

Open `docs/index.html` afterwards. Markdown is rendered with
[`pandoc`](https://pandoc.org) when it is on `PATH` (best quality); a small
dependency-free fallback converter is used otherwise, so the script runs on a
bare Python 3 install.

## What gets generated

| Output | Source |
| --- | --- |
| `index.html` | the feature dashboard (defined in `build.py`) |
| `guide.html` | `README.md` |
| `examples.html` | `Examples.md` |
| `changelog.html` | `Changelog.md` |
| `roadmap.html` | `TODO.md` |
| `backlog.html` | `Backlog.md` |
| `internals.html` | `CLAUDE.md` (only with `--internal`) |
| `views/` | copy of the repo's `views/` gallery |
| `assets/style.css` | written from the `CSS` constant in `build.py` |

Everything here is generated. To change content, edit the Markdown at the
repository root (or the dashboard data / stylesheet in `docs/build.py`) and
re-run the script — don't hand-edit the HTML.

## Publishing

The folder is self-contained and can be served as-is. To publish via GitHub
Pages, point Pages at the `docs/` folder on the default branch (Settings →
Pages → Source: `main` / `/docs`), or copy the folder to any static host.

Cross-page Markdown links (`Examples.md`, `#views`, …) are rewritten to the
generated pages and their anchors automatically.
