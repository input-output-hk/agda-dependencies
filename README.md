# agda-deps: an Agda backend for visualizing lemma dependencies

`agda-deps` is an Agda compiler backend that emits a graph of the dependencies
between definitions, postulates, and incomplete lemmas in an Agda program.
Output is one of:

- a Graphviz **DOT** file,
- an interactive **HTML** page (several [views](#views)),
- or a stable **JSON** artifact (the v2 `graph.json` schema) for downstream tooling.

Each node is coloured by the state of its definition:

| State     | Default colour         | Meaning                                              |
| --------- | ---------------------- | --------------------------------------------------- |
| Defined   | green &nbsp;`#4caf50`  | A regular definition (function, data, record).      |
| Postulate | red &nbsp;`#f44336`    | An `Axiom` / `postulate`.                            |
| Hole      | purple &nbsp;`#9c27b0` | Contains an unsolved meta (`?` in source).           |
| Failed    | orange &nbsp;`#ff9800` | Module whose type-check failed under `--keep-going`. |

The entry point is `src/Main.hs`; the backend lives under `src/AgdaDeps/`.

Runnable recipes: [Examples.md](Examples.md). Shipped work: [Changelog.md](Changelog.md).
Planned / deferred: [TODO.md](TODO.md), [Backlog.md](Backlog.md).

## Prerequisites

- GHC and `cabal-install` satisfying `base >= 4.10 && < 4.23`.
- `Agda >= 2.8 && < 3`. The cabal solver picks the version (no flag): the default
  `cabal.project` pins `Agda ==2.8.0` from Hackage; `cabal.project.agda29` pins an
  upstream 2.9.0 commit. See [Build](#build).

A browser is enough to view HTML output — the self-contained file works over
`file://`. Only `--lazy` output needs an HTTP server.

## Build

```
cabal build
```

builds against the default Agda 2.8.0. For Agda 2.9.0 (a git pin, since it isn't
on Hackage yet):

```
cabal build --project-file=cabal.project.agda29 --builddir=dist-agda29 agda-deps
```

Both produce byte-identical graphs (apart from the `producer` fingerprint), and
CI checks each against the same golden.

### Install a stable binary

For repeated use, or for tooling that shells out to `agda-deps`:

```
cabal install exe:agda-deps --overwrite-policy=always
```

This copies the binary to cabal's `installdir` (`~/.local/bin/` by default; make
sure it's on your `PATH`). `agda-deps --version` reports the git revision, build
date, and GHC of whichever binary is on your `PATH`.

`cabal install` builds from an sdist with no `.git`, so the installed binary
reports `git unknown`. To stamp the commit in:

```
AGDA_DEPS_GIT_REV="$(git rev-parse --short=12 HEAD)" cabal install exe:agda-deps --overwrite-policy=always
```

## Backend flags

Everything after `--` is forwarded to the backend and to Agda's CLI.

- `-o DIR` / `--out-dir=DIR` — write output to `DIR` (`deps.dot`, `deps.html`, or
  `deps.json`). Without it, DOT and JSON go to stdout; HTML requires `-o`. If the
  value is a file path ending in `.html` / `.json` / `.dot` and `--format` is
  unset, the format is inferred from the extension (explicit `--format` wins).
- `--format=dot|html|json` — output format (default: `dot`).
- `--view=VIEW` — HTML view variant. See [Views](#views).
- `--config=PATH` — load a YAML config file. See [YAML config](#yaml-config).
- `--theme=default|light|dark|colorblind` — palette preset for the four state
  colours. `default`/`light` is the standard palette; `dark` is
  `#81c784`/`#ef5350`/`#ba68c8`/`#ffb74d`; `colorblind` is
  `#1b9e77`/`#d95f02`/`#7570b3`/`#e7298a`. Explicit `--color-*` flags still win.
- `--color-defined=#RRGGBB` — colour for defined nodes (default `#4caf50`).
- `--color-postulate=#RRGGBB` — colour for postulates (default `#f44336`).
- `--color-hole=#RRGGBB` — colour for nodes with unsolved holes (default `#9c27b0`).
- `--color-failed=#RRGGBB` — colour for failed modules (default `#ff9800`).
- `--keep-going` — tag modules whose type-check fails as `failed` and proceed
  with whatever loaded, instead of aborting. Every stage is guarded, so a graph
  is still written — with def-level data (states, edges, `--with-signatures`
  types) for every module that elaborated. JSON carries a `failedModules` array;
  DOT emits one coloured node per failed module. Caveats: `failedModules` names
  the module Agda was checking when the error fired (for an import-chain failure,
  possibly the parent, not the failing leaf); and `entryModule` is omitted when
  the entry point itself never elaborated.
- `--skip-agda` — don't invoke Agda; render a module-level graph from a source
  scan (`module …` / `import …` lines) in milliseconds. For huge corpora, broken
  projects, and quick onboarding. Trade-off: no definition graph, no
  D/P/H classification, no source snippets. Module-DAG views render normally;
  definition-level views show empty pods or stubbed metrics.
- `--lenient-imports` — forwarded to Agda as `--allow-unsolved-metas`. Combine
  with `--keep-going` on projects that deliberately commit `?` holes (Agda
  otherwise refuses to *import* a module with open metas). **Incompatible with
  `--safe` dependencies:** `--allow-unsolved-metas` is a global flag, so any
  `--safe` module in the dep closure (e.g. the standard library) aborts the run
  with `[SafeFlagPragma]`. For a `--safe` stdlib, prefer `--keep-going` alone.
- `--resolve-deps` — constrain Agda's search path to the project's `.agda-lib`
  `depend:` closure, expanding into `--no-libraries -i <dir> …` before Agda's CLI
  parser. Useful when multiple versions of a library are registered and Agda
  picks the wrong one (`[AmbiguousTopLevelModuleName]`). Reads `~/.agda/libraries`
  (or `$AGDA_DIR` / `$XDG_CONFIG_HOME`). Falls back silently if the project has no
  `.agda-lib` or resolution fails.
- `--no-externals` — drop external modules (anything outside the project root,
  including pure re-export hubs) from the graph entirely — nodes, edges, the lot.
  JSON keeps a top-level `externals_summary` recording what was dropped.
- `--json-mode=packed|expanded` — the `--format=json` shape. `packed` (default)
  is base64 CSR for large graphs; `expanded` is arrays of records for downstream
  tooling. See [Consuming the JSON output](#consuming-the-json-output).
- `--packed-analytical` — add the per-def analytical arrays the expanded form
  carries (`kinds`/`lines`/`access`/`unsafe`, plus `types` under
  `--with-signatures` and CSR subterm arrays under `--with-term-hashes`) to
  packed's `defs`, so a decoded packed graph is node-for-node identical to
  expanded. Off by default; no effect on expanded output.
- `--with-term-hashes` — walk each definition's elaborated `Term` and emit a
  `Word64` fingerprint per subterm as `definitionSubtermHashes` (with parallel
  `definitionSubtermDepths`) in expanded JSON. Off by default (adds a Term walk,
  ~50–100% wire growth). For downstream AST-level clustering.
- `--min-term-depth=N` — drop subterms below AST depth `N` from the hash list
  (default `3`; `1` disables the filter). Suppresses single-node noise. Ignored
  without `--with-term-hashes`.
- `--with-signatures` — reify each definition's type and emit it as the per-def
  `"type"` field in expanded JSON. As-written (not normalised, no implicit args),
  one line. Off by default.
- `--normalise-signatures` — normalise types before rendering (semantic form).
  No effect without `--with-signatures`.
- `--signature-implicits` — show implicit/irrelevant args in signatures. No
  effect without `--with-signatures`. (Named to avoid clashing with Agda's own
  `--show-implicit`.)
- `--incremental` — per-module caching, both layers keyed on the interface hash
  (+ node-key version + content-option fingerprint). A **fragment cache** under
  `<out-dir>/.agda-deps-cache/` skips the per-definition walk for unchanged
  modules; an **incremental serialise** layer skips re-emitting unchanged output
  (the whole monolithic file on a no-op; in `--lazy` mode, only changed
  `modules/<M>.json` / `snippets/<M>.json`). Output is byte-identical to a
  non-cached run; stale fragments are GC'd. Works on Agda 2.8 and 2.9; disabled
  under `--keep-going`. `rm -rf <out-dir>/.agda-deps-cache` is always safe.
  Caveat: it can't remove Agda's own interface-load cost, the dominant part of a
  warm rebuild.
- `--cache-dir=DIR` — override the `--incremental` cache location. No effect
  without `--incremental`.
- `--quiet` — suppress the "I am working" progress lines on stderr (including the
  config-applied and pre-compute-scan breadcrumbs); warnings and errors still
  print. Mirrors `quiet:` in the YAML config.
- `--version` / `-V` — print the build fingerprint and exit: version, git
  revision (`+` suffix if dirty), build date, GHC — e.g.
  `agda-deps 1.1 (git e34d8c9a+, built Jun 12 2026 08:49:36, ghc 9.14)`. The same
  string is stamped into `graph.json` as `"producer"`. `--numeric-version` prints
  just the number.
- `--emit-schema` — print the JSON Schema for expanded `graph.json` and exit (no
  Agda run). Generated from `AgdaDeps.Backend.Wire`; CI checks it against the
  committed [schema](schema/graph-v2-expanded.schema.json).

The HTML/source flags:

- `--with-source` — embed each definition's source snippet into the HTML;
  clicking a leaf opens it in a side drawer. **Requires `--lazy`.** See
  [Linking to source](#linking-to-source).
- `--agda-html-dir=DIR` — point the views at pages `agda --html` already wrote
  (path *relative to the generated HTML*). Views then show an **Open source**
  link to `DIR/<Module.Name>.html`. Complements `--with-source`; wired into the
  `sunburst-hierarchy` view. Off by default.
- `--lazy` — HTML only: emit a small `deps.html` shell plus a sibling
  `graph.json` and per-module `modules/<M>.json` / `snippets/<M>.json`, loaded
  via `fetch()`. Requires HTTP serving. See
  [Large projects](#large-projects-lazy-output).
- `--exclude=PREFIX` — repeatable. Drop every module named `PREFIX` or starting
  with `PREFIX.`, and edges into/out of them. E.g. `--exclude=Agda.Builtin`.
- `--no-source-for=PREFIX` — repeatable. Skip snippet extraction for matching
  modules (same prefix semantics); they still appear in the graph.
- `--max-snippet-bytes=N` — per-module cap on snippet bundles (default `1000000`;
  a larger module is omitted with a warning). `0` disables the cap.
- `--gzip` — also write a `.gz` sibling next to every JSON file, for an HTTP
  server with `Content-Encoding` negotiation. The page JS still fetches the plain
  `.json`.

Every run also does a **pre-compute** pass: before Agda starts, it scans every
`.agda` / `.lagda*` file under the include path for `module` / `import`
declarations and unions the module-level graph into the output, so modules that
never finished type-checking (under `--keep-going`) still appear with their
import wiring. A no-op union on a fully successful run.

Standard Agda CLI flags are also accepted — `-i DIR` (include path), `-l LIB`,
`--library-file=FILE`, `--no-libraries`, and the trailing positional module.
`--help` shows only the backend's options; `--agda-help` shows Agda's full help.

## Quick start

The `test/` corpus (`Test.agda` importing `Nat`, `Bool`, `List`, `Holes`)
exercises all three colour branches — a postulate (`Holes.magic`) and a hole
(`Holes.incomplete`).

### DOT

```
cabal run agda-deps -- --format=dot -i test/ -o test/ test/Test.agda
dot -Tsvg test/deps.dot -o deps.svg
```

### HTML

```
cabal run agda-deps -- --format=html -i test/ -o test/ test/Test.agda
xdg-open test/deps.html
```

The page supports pan & zoom, collapsible module clusters (defs live inside their
module box, expand on demand), click-to-focus on a leaf's neighbourhood, and a
module-tree sidebar with tri-state visibility checkboxes. Externals (stdlib,
`Agda.Builtin.*`, `depend:` libraries) start hidden — `Toggle externals` shows
them. Other controls: layout selector (force / grid / circle / concentric /
tree), a spacing slider, a cascade-depth dropdown for how many hops a module
click reveals, a transitive-edge filter (precomputed backend-side), and a walker
mode that focuses one module's N-hop neighbourhood at a time.

Under `--lazy` the page opens with only the entry module visible: single-click a
module to reveal its direct imports, double-click to also toggle its definitions.

### Views

Pick one with `--view=VIEW`. All views consume the same v2 `graph.json`; only the
JS app and styling differ.

| View                          | What it does |
| ----------------------------- | ------------ |
| `module-dag-pods` *(default)* | Top-down DAG of expandable module "pods". Best for ≤ ~5k modules; dagre layout in-browser. |
| `cytoscape`                   | Force-directed compound-node viewer (modules as boxes, defs inside). Rich sidebar: search, walker, path mode, transitive-edge filter. |
| `sigma`                       | WebGL module-level renderer (sigma.js + graphology + dagre). Scales to ~1M nodes. DAG/concentric layout, fit button, import side panel. |
| `big-module-dag-pods`         | Viewport-virtualised `module-dag-pods` for ~100k modules. Layout precomputed Haskell-side; minimap navigation. |
| `ide-three-pane`              | File tree + focused subgraph + source pane. Definition-level. |
| `source-centric`              | Code-first with a minimap. Definition-level. |
| `notion-doc`                  | Scrollable cross-linked document. Definition-level. |
| `wiki-backlinks`              | Single-page focus with depends-on / used-by lists. Definition-level. |
| `progress-dashboard`          | Grafana-style KPI board: completeness %, D/P/H/F donut, hot-modules table, most-blocking-defs ranking, hole-density heatmap. Best for "is progress being made?". |
| `critical-path-holes`         | Kanban of proof obligations: holes/postulates upstream of the entry theorem, classified blocking / indirect / postulates / recently-discharged, with dep chains. |
| `sunburst-hierarchy`          | D3 sunburst over the dotted-module tree. Arc fill = state mix; import chords + A→B trail finder. |
| `pixel-grid-overview`         | Every def is a coloured tile, per-module bands; sort/heatmap modes, keyboard cursor, minimap. Inline mode only. |
| `reading-order-narrative`     | Textbook-style topological scroll with a sticky margin mini-graph. Pairs well with `--with-source`. |
| `cartographic-atlas`          | Topographic-map metaphor: continents (module prefixes), elevation (depth from axioms), volcano/sinkhole glyphs for holes/postulates. |

For very large projects start with `big-module-dag-pods` or `sigma`; for broken
projects combine any module-level view with `--skip-agda`. For proof-progress
tracking, `progress-dashboard` and `critical-path-holes` are the most actionable.

```
cabal run agda-deps -- --format=html --view=sigma -i src/ -o out/ src/Main.agda
```

### Custom palette

Override any state colour (DOT and HTML honour the same flags; values must match
`#RRGGBB`):

```
cabal run agda-deps -- --format=html \
  --color-defined=#0288d1 --color-postulate=#d32f2f --color-hole=#fbc02d \
  -i test/ -o test/ test/Test.agda
```

## YAML config

`agda-deps` reads an optional YAML config. Keys mirror the CLI flag names in
kebab-case (`--no-externals` ↔ `no-externals`). Merge order is
**defaults → config → CLI**.

Discovery (first match wins):

1. `--config=PATH`
2. `$AGDA_DEPS_CONFIG`
3. `./.agda-deps.yml` (or `.yaml`)
4. the dotfile in the nearest ancestor containing a `*.agda-lib`

A stderr breadcrumb fires when a config applies (unless `--quiet`).

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

Clicking a leaf can open its Agda source in a side drawer. Pass `--with-source`
**with `--lazy`**; in one run the backend:

1. runs Agda's HTML highlighter on every loaded module (same as `agda --html`),
2. locates each definition's paragraph in the `.agda` source, and
3. slices the highlighted span into a per-module `snippets/<Module>.json` bundle
   the page fetches on demand.

`--with-source` needs `--lazy` because the bundles are fetched at runtime, and
`fetch()` needs HTTP serving:

```
cabal run agda-deps -- --format=html --with-source --lazy -i test/ -o test/ test/Test.agda
cd test && python3 -m http.server 8000   # open http://localhost:8000/deps.html
```

Snippets render with Agda's own highlighting palette. Names whose source isn't
reachable (some builtins/synthetics) get a placeholder. No separate `agda --html`
step is needed. Passing `--with-source` without `--lazy` warns and renders
without snippets.

### Opening the full `agda --html` page (`--agda-html-dir`)

Where `--with-source` *embeds* a snippet, `--agda-html-dir` *links out* to the
whole module page. Point it at existing `agda --html` output (path relative to
the generated HTML) and the views grow an **Open source** affordance:

```
agda --html --html-dir=out/html -i test/ test/Test.agda
cabal run agda-deps -- --format=html --view=sunburst-hierarchy --agda-html-dir=html -i test/ -o out/ test/Test.agda
cd out && python3 -m http.server 8000
```

Each module opens `DIR/<Module.Name>.html`. Wired into the `sunburst-hierarchy`
view; external/builtin modules (no local page) are suppressed. Best served over
HTTP.

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
splices in the leaves. Browsers block `fetch()` on `file://`, so serve over HTTP
(`python3 -m http.server` suffices).

For scale: on a ~21k-node project (~248k leaf edges, ~17k snippets) the initial
load is ~3.2 MB (`deps.html` + `graph.json`) out of ~207 MB on disk; the rest is
per-module files fetched only when opened.

## Running on your own code

Point `-i` at the include path that resolves your imports and pass the top module
as the positional argument:

```
cabal run agda-deps -- --format=html -i src/ -o out/ src/MyMain.agda
```

For a project on the standard library, add its `src/`:

```
cabal run agda-deps -- --format=html -i src/ -i /path/to/agda-stdlib/src -o out/ src/MyMain.agda
```

Imported-library definitions appear as their own module clusters.

## Consuming the JSON output

`--format=json` ships in two shapes, selected by `--json-mode`:

- **packed** (default) — CSR adjacency; per-def state and module indices as
  base64 `Int8`/`Int32` typed arrays. Best for tens of thousands of nodes;
  consumers need a base64 → typed-array decode. `defs` carries only
  `names`/`modules`/`states`/`x`/`y` unless [`--packed-analytical`](#backend-flags)
  adds the `kinds`/`lines`/`access`/`unsafe` (and `types`/`subterm*`) arrays. A
  decoded packed-analytical graph is node-for-node identical to expanded
  (enforced by `schema/packed_analytical_check.py`).
- **expanded** — `definitions` as `{id, name, module, state, kind, x, y}`
  records, `definitionEdges` / `moduleEdges` as qname / module-name pairs, plus a
  `reexports` array. No base64. Carries `"schemaVersion": 2` and
  `"mode": "expanded"`. Best for small fixtures and ad-hoc tooling.

Both forms carry a `"producer"` string (build fingerprint) and a
`"nodeKeyVersion"` integer (node-naming convention, for stale-cache detection);
both are optional and absent `nodeKeyVersion` reads as `1`.

**State letters:** `D` defined, `P` postulate, `H` hole, `F` failed (module-level
marker under `--keep-going`).

**Kind** (from Agda's `theDef`): `function`, `projection`, `datatype`, `record`,
`constructor`, `postulate`, `primitive`, `other`. Filter on these instead of
scraping qnames.

**`unsafe`** (per-def, optional array) — soundness escapes used *directly* (not
transitively): `non-terminating` (`{-# NON_TERMINATING #-}`) and `trustme`
(references `primTrustMe`). Orthogonal to `state`: a def can be `D` and still
carry an escape. Always computed; omitted when empty. `{-# TERMINATING #-}` is
deliberately not surfaced — indistinguishable from an ordinary proven-terminating
def.

**`moduleOptionEscapes`** (top-level, optional) — map from module name to the
file-level `{-# OPTIONS #-}` flags that make `agda --safe` reject it
(`--type-in-type`, `--no-positivity-check`, `--rewriting`, …). Read from each
module's own `OPTIONS` pragma, so a command-line/library default isn't
misattributed. Only safety-relevant flags; only modules with an escape appear;
omitted when none. A per-block `{-# NO_POSITIVITY_CHECK #-}` is a *declaration*
pragma, not `OPTIONS`, so it is not surfaced.

**`definitionEdgesProvenance`** (expanded, optional) — parallel to
`definitionEdges`, tagging each edge `signature | body | module-local | with |
unknown`. Older JSON without it falls back to `unknown`.

**`reexports`** rows: `{ "from", "to", "names": [...] }`, one per
`open import … public`. Names are fully qualified. A row that used `renaming`
also carries a `"renames"` map (`alias → canonical name`), omitted when empty.

The expanded form has a JSON Schema (draft 2020-12) at
[`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json).
Validate with e.g.
`pipx run check-jsonschema --schemafile schema/graph-v2-expanded.schema.json deps.json`;
CI runs this on every build. The committed schema is the *oracle*: the wire shape
is described once in `AgdaDeps.Backend.Wire`, `agda-deps --emit-schema`
regenerates the schema, and CI fails if the two diverge — so the producer can't
gain or drop a field without the schema updating in the same change. The `packed`
form is not schematised.

The `--lazy` on-disk layout (`graph.json` + `modules/*.json` + `snippets/*.json`)
is documented in [CLAUDE.md](CLAUDE.md#v2-graphjson-schema): walk `graph.json`'s
`moduleFiles` manifest to find detail files — don't derive URLs from module names.

## What gets filtered out

To keep the graph readable, the backend ignores compiler-generated names:
pattern-lambdas, `with`-helpers, Kan operations, inlined functions from
instantiated modules, clause-less primitives, `PrimitiveSort`, `DataOrRecSig`,
`GeneralizableVar`, and the `Agda.Primitive.Level` axiom. See `ignoreDef` in
`src/AgdaDeps/Deps.hs`.

Edges *through* ignored defs are preserved: when a kept def references a
`with`-helper that references a real target, the edge `kept-def → real-target` is
reconstructed by a closure pass over the ignored defs' out-edges. See
`contractIgnoredEdges` in `src/AgdaDeps/Deps.hs`.

## Relevant links

- <https://unimath.github.io/agda-unimath/VISUALIZATION.html>

## AI disclaimer

I used Claude Code to generate features on this project. Most are proofs of
concept for visualizing and exploring Agda projects. Feel free to edit them.
