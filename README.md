# agda-deps: an Agda backend for visualizing lemma dependencies

`agda-deps` is an Agda compiler backend. It runs inside the type-checker and
emits a graph of the dependencies between definitions, postulates, and
incomplete lemmas. Output is one of:

- a Graphviz **DOT** file,
- an interactive **HTML** page (one of several [views](#views)),
- a stable **JSON** artifact (the v2 `graph.json` schema) for downstream tooling.

Each node is coloured by the state of its definition:

| State     | Colour            | Meaning                                              |
| --------- | ----------------- | ---------------------------------------------------- |
| Defined   | green `#4caf50`   | A function, datatype, record, or constructor.        |
| Postulate | red `#f44336`     | An `Axiom` / `postulate`.                            |
| Hole      | purple `#9c27b0`  | Contains an unsolved meta (`?` in source).           |
| Failed    | orange `#ff9800`  | Module whose type-check failed under `--keep-going`. |

Examples: [Examples.md](Examples.md). Changes: [Changelog.md](Changelog.md).
Planned / deferred: [TODO.md](TODO.md), [Backlog.md](Backlog.md).

## Prerequisites

- GHC and `cabal-install` with `base >= 4.10 && < 4.23`.
- `Agda >= 2.8 && < 3`. The cabal solver picks the version: the default
  `cabal.project` pins `Agda ==2.8.0`; `cabal.project.agda29` pins a 2.9.0 git
  commit.

A browser is enough to view HTML output over `file://`. Only `--lazy` output
needs an HTTP server.

## Build

```
cabal build                                                                        # Agda 2.8.0 (default)
cabal build --project-file=cabal.project.agda29 --builddir=dist-agda29 agda-deps   # Agda 2.9.0
```

Both produce byte-identical graphs (apart from the `producer` fingerprint).

Install a stable binary for repeated use or for tooling that shells out:

```
cabal install exe:agda-deps --overwrite-policy=always
```

It lands in cabal's `installdir` (`~/.local/bin/` by default; ensure it is on
`PATH`). `agda-deps --version` prints the build fingerprint — the same string
stamped into `graph.json` as `producer`.

## Quick start

`test/Test.agda` (entry of the `test/` corpus) includes a postulate
(`Holes.magic`) and a hole (`Holes.incomplete`), so its graph shows all states.

DOT:

```
cabal run agda-deps -- --format=dot -i test/ -o test/ test/Test.agda
dot -Tsvg test/deps.dot -o deps.svg
```

HTML:

```
cabal run agda-deps -- --format=html -i test/ -o test/ test/Test.agda
xdg-open test/deps.html
```

The HTML page has pan & zoom, collapsible module clusters, click-to-focus,
a module-tree sidebar, layout/spacing controls, and a transitive-edge filter.
Externals (stdlib, `Agda.Builtin.*`, `depend:` libraries) start hidden. Under
`--lazy` only the entry module shows at first; click a module to reveal its
imports.

Run on your own code by pointing `-i` at the include path that resolves your
imports (repeat `-i` for the standard library) and passing the top module:

```
cabal run agda-deps -- --format=html -i src/ -i /path/to/agda-stdlib/src -o out/ src/MyMain.agda
```

## Backend flags

Everything after `--` is forwarded to the backend and to Agda's CLI. Standard
Agda flags are accepted — `-i DIR` (include path), `-l LIB`,
`--library-file=FILE`, `--no-libraries`, and the trailing positional module.
`--help` lists the backend's options; `--agda-help` shows Agda's.

- `-o DIR` / `--out-dir=DIR` — output directory (`deps.dot|html|json`). Without
  it, DOT and JSON go to stdout; HTML requires it. A value ending in
  `.html`/`.json`/`.dot` also sets the format unless `--format` is given.
- `--format=dot|html|json` — output format (default `dot`).
- `--view=VIEW` — HTML view. See [Views](#views).
- `--config=PATH` — load a YAML config. See [YAML config](#yaml-config).
- `--theme=default|light|dark|colorblind` — palette preset for the four state
  colours. `default`/`light` is the standard palette; `dark` is
  `#81c784`/`#ef5350`/`#ba68c8`/`#ffb74d`; `colorblind` is
  `#1b9e77`/`#d95f02`/`#7570b3`/`#e7298a`. Explicit `--color-*` flags win.
- `--color-defined|postulate|hole|failed=#RRGGBB` — override a state colour
  (defaults `#4caf50` / `#f44336` / `#9c27b0` / `#ff9800`).
- `--keep-going` — don't abort on a type-check error: tag the failing module
  `failed` and emit whatever loaded, with def-level data for every module that
  elaborated. JSON carries a `failedModules` array; DOT emits one node per
  failed module. `failedModules` names the module Agda was checking when the
  error fired (possibly a parent, not the failing leaf); `entryModule` is
  omitted if the entry point never elaborated.
- `--skip-agda` — don't invoke Agda; render a module-level graph from a source
  scan (`module` / `import` lines) in milliseconds. No definition graph, no
  D/P/H states, no snippets — module-DAG views only.
- `--lenient-imports` — forward `--allow-unsolved-metas` to Agda, for projects
  that deliberately commit `?` holes; combine with `--keep-going`. Incompatible
  with `--safe` dependencies (any `--safe` module in the closure aborts with
  `[SafeFlagPragma]`); for a `--safe` stdlib use `--keep-going` alone.
- `--resolve-deps` — constrain Agda's search path to the project's `.agda-lib`
  `depend:` closure. Fixes `[AmbiguousTopLevelModuleName]` when several versions
  of a library are registered. No-op if there is no `.agda-lib`.
- `--no-externals` — drop everything outside the project root (nodes and edges).
  JSON keeps a top-level `externals_summary` of what was dropped.
- `--json-mode=packed|expanded` — the `--format=json` shape (default `packed`).
  See [Consuming the JSON output](#consuming-the-json-output).
- `--packed-analytical` — add the per-def analytical arrays (`kinds`/`lines`/
  `access`/`unsafe`, plus `types` and subterm arrays when those are enabled) to
  packed, so a decoded packed graph is node-for-node identical to expanded.
- `--with-term-hashes` — emit a `Word64` fingerprint per definition subterm
  (`definitionSubtermHashes` + `definitionSubtermDepths`) in expanded JSON. Off
  by default (adds a Term walk, ~50–100% wire growth).
- `--min-term-depth=N` — drop subterms below AST depth `N` (default `3`; `1`
  disables). Needs `--with-term-hashes`.
- `--with-signatures` — emit each definition's reified type as the per-def
  `type` field in expanded JSON (as written, one line). Off by default.
- `--normalise-signatures` — normalise types before rendering. Needs
  `--with-signatures`.
- `--signature-implicits` — show implicit/irrelevant args. Needs
  `--with-signatures`.
- `--incremental` — per-module caching under `<out-dir>/.agda-deps-cache/`,
  keyed on the interface hash. Skips the per-definition walk and the re-emission
  of unchanged output; result is byte-identical to a non-cached run. Disabled
  under `--keep-going`; deleting the cache dir is always safe.
- `--cache-dir=DIR` — override the cache location. Needs `--incremental`.
- `--quiet` — suppress the progress lines on stderr; warnings and errors still
  print.
- `--version` / `-V` — print the build fingerprint (version, git rev, build
  date, GHC) and exit. `--numeric-version` prints just the number.
- `--emit-schema` — print the expanded `graph.json` JSON Schema and exit.

HTML / source flags:

- `--with-source` — embed each definition's source snippet; clicking a leaf
  opens it in a side drawer. **Requires `--lazy`.** See
  [Linking to source](#linking-to-source).
- `--agda-html-dir=DIR` — link the views to existing `agda --html` pages at
  `DIR/<Module.Name>.html` (path relative to the generated HTML). Wired into the
  `sunburst-hierarchy` view.
- `--lazy` — HTML only: emit a small `deps.html` shell plus a sibling
  `graph.json` and per-module JSON loaded via `fetch()` (needs HTTP serving).
  See [Large projects](#large-projects-lazy-output).
- `--exclude=PREFIX` — repeatable. Drop modules named `PREFIX` or `PREFIX.*`
  and their edges (e.g. `--exclude=Agda.Builtin`).
- `--no-source-for=PREFIX` — repeatable. Skip snippets for matching modules;
  they still appear in the graph.
- `--max-snippet-bytes=N` — per-module snippet cap (default `1000000`; `0`
  disables).
- `--gzip` — also write a `.gz` next to every JSON file (the page still fetches
  the plain `.json`).

Every run also scans sources for `module` / `import` declarations and unions
that module-level graph into the output, so modules that never type-checked
(under `--keep-going`) still appear with their import wiring.

## Views

Pick one with `--view=VIEW`. All views consume the same v2 `graph.json`; only
the JS app and styling differ.

| View                          | What it does |
| ----------------------------- | ------------ |
| `module-dag-pods` *(default)* | Top-down DAG of expandable module "pods". Best for ≤ ~5k modules; dagre layout in-browser. |
| `cytoscape`                   | Force-directed compound-node viewer (modules as boxes, defs inside), rich sidebar. |
| `sigma`                       | WebGL module-level renderer (sigma.js + graphology + dagre). Scales to ~1M nodes. |
| `big-module-dag-pods`         | Viewport-virtualised `module-dag-pods` for ~100k modules; layout precomputed Haskell-side, minimap. |
| `ide-three-pane`              | File tree + focused subgraph + source pane. Definition-level. |
| `source-centric`              | Code-first with a minimap. Definition-level. |
| `notion-doc`                  | Scrollable cross-linked document. Definition-level. |
| `wiki-backlinks`              | Single-page focus with depends-on / used-by lists. Definition-level. |
| `progress-dashboard`          | KPI board: completeness %, D/P/H/F donut, hot-modules table, most-blocking defs, hole-density heatmap. |
| `critical-path-holes`         | Kanban of proof obligations upstream of the entry theorem, with dep chains. |
| `sunburst-hierarchy`          | D3 sunburst over the dotted-module tree; arc fill = state mix, import chords, A→B trail finder. |
| `pixel-grid-overview`         | Every def a coloured tile in per-module bands; sort/heatmap modes, minimap. Inline mode only. |
| `reading-order-narrative`     | Topological scroll with a sticky margin mini-graph. Pairs with `--with-source`. |
| `cartographic-atlas`          | Topographic-map metaphor: continents (prefixes), elevation (depth), glyphs for holes/postulates. |

For very large projects start with `big-module-dag-pods` or `sigma`; for broken
projects combine any module-level view with `--skip-agda`; for proof-progress
tracking use `progress-dashboard` or `critical-path-holes`.

```
cabal run agda-deps -- --format=html --view=sigma -i src/ -o out/ src/Main.agda
```

Override any state colour (DOT and HTML honour the same flags):

```
cabal run agda-deps -- --format=html \
  --color-defined=#0288d1 --color-postulate=#d32f2f --color-hole=#fbc02d \
  -i test/ -o test/ test/Test.agda
```

## YAML config

`agda-deps` reads an optional YAML config. Keys mirror the CLI flags in
kebab-case (`--no-externals` ↔ `no-externals`). Merge order is
**defaults → config → CLI**. Discovery (first match wins): `--config=PATH`,
`$AGDA_DEPS_CONFIG`, `./.agda-deps.yml` (or `.yaml`), then the dotfile in the
nearest ancestor with a `*.agda-lib`.

```yaml
format: html
view: module-dag-pods
theme: dark
no-externals: true
keep-going: true
incremental: true
cache-dir: .agda-deps-cache
with-source: true
lazy: true
exclude:
  - Agda.Builtin
  - Data
no-source-for:
  - Foreign
color-defined: "#4caf50"
max-snippet-bytes: 1000000
json-mode: expanded
gzip: false
quiet: false
out-dir: build/deps
with-term-hashes: false       # per-def subterm fingerprints
min-term-depth: 3             # filter; needs with-term-hashes
with-signatures: false        # per-def rendered type signatures
normalise-signatures: false   # normalise types; needs with-signatures
signature-implicits: false    # show implicit args; needs with-signatures
```

Repeatable flags (`exclude`, `no-source-for`) take YAML lists. Explicit
`--color-*` CLI flags still win over `theme:`.

## Linking to source

`--with-source` (with `--lazy`) runs Agda's HTML highlighter on every loaded
module, slices each definition's highlighted span into a per-module
`snippets/<Module>.json`, and fetches it on demand when a leaf is clicked. It
requires `--lazy` because `fetch()` needs HTTP serving:

```
cabal run agda-deps -- --format=html --with-source --lazy -i test/ -o test/ test/Test.agda
cd test && python3 -m http.server 8000   # open http://localhost:8000/deps.html
```

Names whose source isn't reachable (some builtins/synthetics) get a placeholder.
Passing `--with-source` without `--lazy` warns and renders without snippets.

`--agda-html-dir=DIR` instead *links out* to whole `agda --html` module pages
you have already generated (`DIR/<Module.Name>.html`, path relative to the
generated HTML); the views grow an **Open source** link. Wired into the
`sunburst-hierarchy` view.

## Large projects: lazy output

`--lazy` splits the output into a small page shell plus on-demand JSON, so the
initial page is tiny regardless of project size:

```
cabal run agda-deps -- --format=html --with-source --lazy -i src/ -o out/ src/Main.agda
cd out && python3 -m http.server 8000
```

Layout under `-o`:

```
deps.html              ← small shell, no inlined data
graph.json             ← module-level skeleton:
                       ·   modules, moduleEdges (compact A→B pairs)
                       ·   moduleFiles: name → modules/<Module>.json  (the manifest)
                       ·   bundleFiles: name → snippets/<Module>.json  (only with --with-source)
modules/<Module>.json  ← that module's leaves + edges (detail-<hash>.json for non-safe names)
snippets/<Module>.json ← per-module snippet bundle (bundle-<hash>.json fallback)
```

On load the shell fetches only `graph.json` and renders module boxes plus
aggregated edges; clicking a module fetches its `modules/<Module>.json` and
splices in the leaves. Browsers block `fetch()` on `file://`, so serve over HTTP.

## Consuming the JSON output

`--format=json` ships in two shapes, selected by `--json-mode`:

- **packed** (default) — CSR adjacency; per-def state and module indices as
  base64 `Int8`/`Int32` arrays (consumers decode base64 → typed array). `defs`
  carries `names`/`modules`/`states`/`x`/`y` unless
  [`--packed-analytical`](#backend-flags) adds the `kinds`/`lines`/`access`/
  `unsafe` (and `types`/`subterm*`) arrays. Best for tens of thousands of nodes.
- **expanded** — `definitions` as `{id, name, module, state, kind, x, y}`
  records, `definitionEdges` / `moduleEdges` as qname / module-name pairs, plus
  a `reexports` array. No base64. Carries `"schemaVersion": 2` and
  `"mode": "expanded"`. Best for small fixtures and ad-hoc tooling.

Both forms carry `"producer"` (build fingerprint) and `"nodeKeyVersion"` (node
naming convention, for stale-cache detection; absent reads as `1`).

- **State letters** — `D` defined, `P` postulate, `H` hole, `F` failed
  (module-level marker under `--keep-going`).
- **Kind** (from Agda's `theDef`) — `function`, `projection`, `datatype`,
  `record`, `constructor`, `postulate`, `primitive`, `other`. Filter on these
  instead of scraping qnames.
- **`unsafe`** (per-def, optional) — soundness escapes used *directly*:
  `non-terminating` (`{-# NON_TERMINATING #-}`) and `trustme` (references
  `primTrustMe`). Orthogonal to `state`. Omitted when empty. `{-# TERMINATING #-}`
  is not surfaced (indistinguishable from an ordinary proven-terminating def).
- **`moduleOptionEscapes`** (top-level, optional) — module → the file-level
  `{-# OPTIONS #-}` flags that make `agda --safe` reject it (`--type-in-type`,
  `--no-positivity-check`, `--rewriting`, …). Read from each module's own
  `OPTIONS` pragma. Only safety-relevant flags; omitted when none.
- **`definitionEdgesProvenance`** (expanded, optional) — parallel to
  `definitionEdges`, tagging each edge `signature | body | module-local | with |
  unknown`. Absent falls back to `unknown`.
- **`reexports`** rows — `{ "from", "to", "names": [...] }`, one per
  `open import … public`; a row that used `renaming` also carries a `"renames"`
  map (`alias → canonical name`).

The expanded form has a JSON Schema (draft 2020-12) at
[`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json).
Validate with e.g.
`pipx run check-jsonschema --schemafile schema/graph-v2-expanded.schema.json deps.json`.
The wire shape is described once in `AgdaDeps.Backend.Wire`; `agda-deps
--emit-schema` regenerates the schema from it. The `packed` form is not
schematised.

## What gets filtered out

To keep the graph readable, the backend ignores compiler-generated names:
pattern-lambdas, `with`-helpers, Kan operations, inlined functions from
instantiated modules, clause-less primitives, `PrimitiveSort`, `DataOrRecSig`,
`GeneralizableVar`, and the `Agda.Primitive.Level` axiom (`ignoreDef` in
`src/AgdaDeps/Deps.hs`).

Edges *through* ignored defs are preserved: when a kept def references a
`with`-helper that references a real target, the edge `kept-def → real-target`
is reconstructed by a closure pass (`contractIgnoredEdges`, same file).

## AI disclaimer

I used Claude Code to generate features on this project. Most are proofs of
concept for visualizing and exploring Agda projects. Feel free to edit them.
