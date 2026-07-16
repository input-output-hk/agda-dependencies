# agda-deps: An Agda backend for visualizing lemma dependencies.

`agda-deps` is an Agda compiler backend that produces a graph of the dependencies between definitions, postulates, and incomplete lemmas in an Agda program. Output can be:

- a Graphviz **DOT** file,
- a self-contained **HTML** page in one of several interactive views (see [Views](#views) below),
- or a stable **JSON** artifact (the v2 graph.json schema) for downstream tooling.

Each node is colored by the state of the underlying definition:

| State       | Default color           | What it means                                                |
| ----------- | ----------------------- | ------------------------------------------------------------ |
| Defined     | green &nbsp;`#4caf50`   | A regular definition (function with clauses, data, record). |
| Postulate   | red &nbsp;`#f44336`     | An `Axiom` / `postulate`.                                    |
| Hole        | purple &nbsp;`#9c27b0`  | Contains an unsolved meta (`?` in source).                   |
| Failed      | orange &nbsp;`#ff9800`  | Module whose type-check failed under `--keep-going`.         |

The executable's entry point is `src/Main.hs`; the backend logic lives under `src/AgdaDeps/`.

For runnable examples (one per command, with empirical defaults
explained) see [Examples.md](Examples.md). For shipped work see
[Changelog.md](Changelog.md); for forward-looking work
[TODO.md](TODO.md); for deferred ideas
[Backlog.md](Backlog.md).

## Prerequisites

- GHC and `cabal-install` recent enough to satisfy `base >= 4.10 && < 4.23`.
- The `Agda >= 2.8 && < 3` library is required. `agda-deps` builds against either Agda 2.8 or 2.9, selected by the cabal solver (no flag). The default `cabal.project` pins 2.9 to a specific upstream commit on `github.com/agda/agda` (2.9.0 isn't on Hackage yet); `cabal build` fetches and builds it automatically (one-time cost, a few minutes). To build against Agda 2.8.0 (from Hackage, on GHC 9.6) instead, use `cabal.project.agda28` — see [Build](#build).

A browser is needed to view HTML output; no server is required — the generated file works over `file://`.

## Build

```
cabal build
```

To build against Agda 2.8.0 (from Hackage, on GHC 9.6) instead of the
default pinned 2.9:

```
cabal build --project-file=cabal.project.agda28 --builddir=dist-agda28 agda-deps
```

Both produce byte-identical graphs (apart from the build-specific
`producer` fingerprint stamped into `graph.json`).

### Install a stable binary

For repeated use (and for tooling that shells out to `agda-deps`),
install it onto a stable path rather than calling `cabal run` or
hunting for the binary under `dist-newstyle/`:

```
cabal install exe:agda-deps --overwrite-policy=always
```

This copies the binary to cabal's `installdir` (`~/.local/bin/` by
default, or wherever your `~/.cabal/config` points; pass
`--installdir=DIR` to override). Make sure that directory is on your
`PATH`. The installed binary respects the project's `cabal.project`,
so it builds against the pinned Agda 2.9 like `cabal build` does.

Verify which build is on your `PATH` with `agda-deps --version` — it
reports the git revision, build date, and GHC, so there's no need to
inspect `dist-newstyle/` mtimes or `/proc/<pid>/exe` to answer "which
build is this?".

`cabal install` builds from an sdist tarball, which has no `.git`, so
by default the installed binary reports `git unknown` (the build date
and GHC are still captured fresh). To stamp the commit into the
installed binary too, pass it through the environment:

```
AGDA_DEPS_GIT_REV="$(git rev-parse --short=12 HEAD)" cabal install exe:agda-deps --overwrite-policy=always
```

## Backend flags

Everything after `--` is forwarded to the backend (and to Agda's CLI):

- `-o DIR` / `--out-dir=DIR` — write output to `DIR` (`deps.dot`, `deps.html`, or `deps.json`). If omitted, DOT and JSON print to stdout; HTML requires `-o`. When `-o` is given a file path ending in `.html` / `.json` / `.dot` and `--format` is not explicitly set, the format is inferred from the extension; explicit `--format` always wins.
- `--format=dot|html|json` — choose output format (default: `dot`; see auto-inference above).
- `--view=VIEW` — pick an HTML view variant. One of `module-dag-pods` (default), `cytoscape`, `ide-three-pane`, `source-centric`, `notion-doc`, `wiki-backlinks`, `sigma`, `big-module-dag-pods`, `critical-path-holes`, `progress-dashboard`, `cartographic-atlas`, `sunburst-hierarchy`, `reading-order-narrative`, `pixel-grid-overview`. See [Views](#views).
- `--config=PATH` — load a YAML config file (overrides discovery; see [YAML config](#yaml-config)).
- `--theme=default|light|dark|colorblind` — palette preset for the four state colours. `default` / `light`: the standard palette (`#4caf50` / `#f44336` / `#9c27b0` / `#ff9800`); `dark`: `#81c784` / `#ef5350` / `#ba68c8` / `#ffb74d`; `colorblind`: `#1b9e77` / `#d95f02` / `#7570b3` / `#e7298a`. Explicit `--color-*` flags still win over the theme.
- `--color-defined=#RRGGBB` — color for fully-defined nodes (default: `#4caf50`, green).
- `--color-postulate=#RRGGBB` — color for postulates (default: `#f44336`, red).
- `--color-hole=#RRGGBB` — color for nodes containing unsolved holes/metas (default: `#9c27b0`, purple).
- `--color-failed=#RRGGBB` — color for modules whose type-check failed under `--keep-going` (default: `#ff9800`, orange).
- `--keep-going` — when Agda's type-checker raises an error on some module, tag that module as `failed` in the graph and proceed with whatever loaded successfully, instead of aborting. The HTML view colours failed modules with `--color-failed`; the JSON output carries a `failedModules` array; DOT emits a single coloured node per failed module. Without this flag the backend behaves like upstream Agda — any type-check error aborts the run with no output. The partial pass is best-effort all the way down: every stage is guarded, so a definition / module / interface that trips an internal error is skipped with a stderr breadcrumb and **a graph is still written** — including def-level data (states, edges, `--with-signatures` types) for every module that did elaborate. Two caveats: `failedModules` names the module Agda was busy with when the error fired, which for an import-chain failure can be the importing parent rather than the failing leaf; and `entryModule` is omitted when the entry point itself never finished elaborating.
- `--skip-agda` — don't invoke Agda at all. Renders a module-level graph straight from the source-file scan (`module …` / `import …` lines) in milliseconds, no matter how large the project. Useful for huge corpora, broken projects that don't type-check at all, and quick repo onboarding. Trade-off: no definition graph, no Defined/Postulate/Hole classification, no source snippets — those all need Agda's elaborator. Module-DAG views (`--view=cytoscape`, `module-dag-pods`, `sigma`, `big-module-dag-pods`, `cartographic-atlas`, `sunburst-hierarchy`) render normally; definition-level views (`ide-three-pane`, `source-centric`, `notion-doc`, `wiki-backlinks`, `reading-order-narrative`, `pixel-grid-overview`, `progress-dashboard`, `critical-path-holes`) show empty pods or stubbed metrics.
- `--lenient-imports` — forwarded to Agda as `--allow-unsolved-metas`. Combine with `--keep-going` on projects whose commits deliberately contain `?` holes (Agda otherwise refuses to *import* a module with open metas, even under `--keep-going`). **Incompatible with `--safe` dependencies.** `--allow-unsolved-metas` is a *global* Agda flag, so the moment any `--safe` module in your transitive imports (notably the standard library) is loaded, Agda rejects it with `[SafeFlagPragma] The --safe mode does not allow OPTIONS pragma --allow-unsolved-metas` and the run aborts. For projects built on a `--safe` stdlib, prefer `--keep-going` alone — it tolerates a failing module without enabling lenient metas across the dep closure. Per-module hole tolerance would require an upstream Agda change.
- `--resolve-deps` — constrain Agda's search path to the project's `.agda-lib` `depend:` closure. Expands into `--no-libraries -i <dir> -i <dir> ...` before Agda's CLI parser runs. Useful when multiple versions of the same library are registered (e.g. both `standard-library-2.2` and `standard-library-2.4`) and Agda's resolver picks the wrong one, producing `[AmbiguousTopLevelModuleName]` on a plain `open import Level`. agda-deps reads `~/.agda/libraries` (or `$AGDA_DIR/libraries` / `$XDG_CONFIG_HOME/agda/libraries`) to look up each declared dependency, walks the transitive `depend:` closure, and pins the resulting include directories explicitly. Falls back silently to default behaviour if the project has no `.agda-lib`, no `depend:` entries, or any dependency can't be resolved.
- `--no-externals` — drop external modules (anything outside the project root, plus modules referenced but not scanned) from the rendered graph entirely — nodes, edges, the lot. Cleaner than asking users to curate `--exclude=PREFIX` lists. This includes pure *re-export hubs* — a module that only `open … public`s names from elsewhere and so contributes no definition of its own (e.g. a stdlib umbrella like `Data.List`) is still recognised as external and dropped. The JSON additionally retains a top-level `externals_summary` field listing the dropped module names and (per module) their postulate names, so downstream tooling that wants a diagnostic record of the trusted base still has the data.
- `--json-mode=packed|expanded` — choose the `--format=json` shape. Packed (default) is base64-encoded CSR for compactness on large graphs; expanded is the obvious arrays-of-records shape for downstream tooling. See [Consuming the JSON output](#consuming-the-json-output).
- `--packed-analytical` — augment `--json-mode=packed`'s `defs` object with the per-definition analytical arrays the expanded form carries: `kinds`/`lines`/`access`/`unsafe` (always), `types` (under `--with-signatures`), and CSR-packed `subtermOffsets`/`subtermHashes`/`subtermDepths` (under `--with-term-hashes`). Lets a downstream tool keep packed's ~5× size win **and** full analytical fidelity — a decoded packed-analytical graph is node-for-node identical to the expanded form (verified by `schema/packed_analytical_check.py`). Off by default (packed output is otherwise byte-identical to before); no effect on expanded output (which already carries these fields). The new arrays are base64 little-endian typed arrays; `access` is 3-valued (`0`=unknown/absent, `1`=public, `2`=private), `lines` uses `-1` for unknown, `types` uses `null`, `unsafe` is an `Int8` bitmask (bit 0 = `non-terminating`, bit 1 = `trustme`; `0` = no escapes).
- `--with-term-hashes` — walk every definition's elaborated `Term` (signature plus every clause body), canonicalise each subterm (de-Bruijn indices, source positions stripped, `MetaV` identities wildcarded, `Hiding` bit preserved), and emit a per-def array of `Word64` fingerprints as `definitionSubtermHashes` (plus a parallel `definitionSubtermDepths` array carrying the AST depth of each emitted subterm) in expanded JSON. Off by default — adds a Term walk per definition and bloats the wire format by 50–100% on real corpora. Intended for downstream AST-level clustering tooling.
- `--min-term-depth=N` — drop subterms below the given AST depth from the emitted hash list. Default `3`; `1` disables the filter. The default suppresses single-node noise (`Var`, `Lit`, `Sort`, `Level`) that would otherwise dominate cluster ranking. Ignored without `--with-term-hashes`.
- `--with-signatures` — render each definition's type signature (the type-checker's `reify` of its type) and emit it as the per-def `"type"` field in expanded JSON. Shown *as-written*: not normalised, with Agda's default printing (implicit *arguments* at use sites suppressed — no `--show-implicit`; implicit binders in the signature still appear), collapsed to one line. Off by default — adds a reify + pretty-print per definition. Surfaced as the per-def `"type"` field for downstream tooling.
- `--normalise-signatures` — `normalise` each type before rendering it (semantic, fully-reduced form rather than as-written). Off by default; no effect without `--with-signatures`.
- `--signature-implicits` — render type signatures with implicit (and irrelevant) arguments shown. Off by default; no effect without `--with-signatures`. (Named to avoid clashing with Agda's own `--show-implicit`.)
- `--incremental` — per-module caching to speed up rebuilds. Two layers, both keyed on the module's interface hash (which folds in the transitive imports — the same mechanism that decides `.agdai` validity), the node-key convention version, and a fingerprint of the content-affecting options. (1) A **fragment cache** under `<out-dir>/.agda-deps-cache/` skips the per-definition backend walk for unchanged modules (`Skip`ped and served from cache; only the changed cone is re-walked). (2) An **incremental serialise** layer skips re-emitting unchanged output: a no-op rebuild of the monolithic `deps.json` / `deps.html` is skipped entirely when nothing recompiled and the output context is unchanged, and in `--lazy` mode only changed modules' `modules/<M>.json` / `snippets/<M>.json` files are rewritten. Output is byte-identical to a non-cached run. Stale fragments for deleted/renamed modules are garbage-collected automatically. Works on both Agda 2.8 and 2.9 (fragments serialise via `Data.Binary`); disabled under `--keep-going`. `rm -rf <out-dir>/.agda-deps-cache` is always safe. **Caveat:** the dominant cost of a warm rebuild on a large corpus is Agda's own interface load, which a backend cannot avoid; `--incremental` removes our per-definition walk and the output re-emit, but not that floor.
- `--cache-dir=DIR` — override the `--incremental` cache location (fragments + serialise manifest). Default: `<out-dir>/.agda-deps-cache`. No effect without `--incremental`.
- `--version` / `-V` — report this binary's full build fingerprint and exit: version, git revision (with a `+` suffix for a dirty tree), build date, and compiling GHC, e.g. `agda-deps 1.1 (git e34d8c9a+, built Jun 12 2026 08:49:36, ghc 9.14)`. The same string is stamped into `graph.json` as `"producer"`. (Agda has its own `--version`; we intercept first so the answer identifies *this* binary, not Agda.) Use `--numeric-version` for just the bare version number (`1.1`) when tooling needs to parse it.
- `--emit-schema` — print the JSON Schema for expanded `graph.json` to stdout and exit (no Agda run, no input file needed). The schema is generated from the producer's own single source of truth (`AgdaDeps.Backend.Wire`); CI checks it against the committed [`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json). See [Consuming the JSON output](#consuming-the-json-output).

Independently of `--keep-going`, every run does a **pre-compute** pass: before Agda starts, the backend scans every `.agda` / `.lagda*` file under your `-i` / `--include-path` directories for `module` / `import` declarations. The discovered module-level graph is unioned into the rendered output, so modules whose sub-tree never finished type-checking (under `--keep-going`) still appear with their import wiring; for runs that fully succeed it's a no-op union. A single stderr line summarises what the scan found.
- `--with-source` — embed each definition's source snippet into the HTML output. Clicking a leaf opens just that definition (signature + body, plus the surrounding paragraph) in a side drawer. See [Linking to source](#linking-to-source).
- `--agda-html-dir=DIR` — point the HTML views at the pages `agda --html` already wrote (a path **relative to the generated HTML**, e.g. `html`). Views then surface an **Open source** affordance that opens `DIR/<Module.Name>.html` — the real, fully cross-linked Agda page. Complements `--with-source` (which embeds a per-definition snippet); this links out to the whole file instead. Currently wired into the `sunburst-hierarchy` view. Off by default. See [Linking to source](#linking-to-source).
- `--lazy` — HTML output only: emit a small `deps.html` shell plus a sibling `graph.json` and per-module `snippets/<bundle>.json` files instead of a single self-contained file. The shell loads data lazily via `fetch()`, so the initial page is tiny no matter how large the project. Requires the output directory to be served over HTTP (e.g. `python -m http.server`); browsers block `fetch()` on `file://`. See [Large projects: lazy output](#large-projects-lazy-output).
- `--exclude=PREFIX` — repeatable. Drop every module whose name is `PREFIX` or starts with `PREFIX.`. Excluded modules never enter the graph and edges into/out of them are filtered out. Useful for hiding stdlib subtrees you don't care about — e.g. `--exclude=Agda.Builtin --exclude=Data --exclude=Algebra`.
- `--no-source-for=PREFIX` — repeatable. Skip source-snippet extraction for modules matching `PREFIX` (same prefix-match semantics as `--exclude`). The modules still appear in the graph; their leaves just show the "no source available" fallback when clicked. Cuts the cost of running Agda's HTML highlighter over stdlib while keeping the graph structure intact.
- `--max-snippet-bytes=N` — per-module size cap on snippet bundles, in bytes (default: `1000000`, i.e. 1 MB). A module whose rendered bundle exceeds the cap is omitted entirely (warning to stderr). `--max-snippet-bytes=0` disables the cap.
- `--gzip` — also write a `.gz` sibling next to every JSON file (`graph.json.gz`, `modules/*.json.gz`, `snippets/*.json.gz`). The current page JS only fetches the plain `.json` files; the `.gz` siblings exist so an HTTP server with `Content-Encoding` negotiation (`caddy`, `nginx`, etc.) can serve them transparently. `python -m http.server` will not.

Standard Agda CLI flags are also accepted; in particular:

- `-i DIR` — Agda include path (where to look for imported modules).
- `-l LIB` — use Agda library `LIB`.
- `--library-file=FILE` — use `FILE` instead of the standard libraries file.
- `--no-libraries` — don't consult any `.agda-libraries` file.
- The trailing positional argument is the Agda module to compile.

`--help` prints only the backend's options (the Agda compiler's hundreds of flags are *not* shown). Use `--agda-help` to see Agda's full upstream help.

## Quick start

The repo ships with a small test corpus under `test/` (`Test.agda` imports `Nat`, `Bool`, `List`, and `Holes`). It includes one postulate (`Holes.magic`) and one definition with a hole (`Holes.incomplete`), so all three color branches are exercised.

### DOT output

Produce a DOT file and render it with Graphviz:

```
cabal run agda-deps -- --format=dot -i test/ -o test/ test/Test.agda
dot -Tsvg test/deps.dot -o deps.svg
```

Or, for the legacy stdout flow (no `-o`):

```
cabal run agda-deps -- -i test/ test/Test.agda > Res.dot
```

### HTML output

```
cabal run agda-deps -- --format=html -i test/ -o test/ test/Test.agda
xdg-open test/deps.html   # or just open the file in any browser
```

The page gives you:

- **Pan & zoom** over the graph.
- **Module clusters** — each Agda module is a compound (parent) node containing its definitions. Modules start collapsed; click a module (or its `+` / `-` cue) to expand on demand. Cross-module dependencies show as meta-edges between collapsed modules.
- **Click-to-focus** — clicking a leaf node fades everything except that node and its immediate in/out neighbors. Click empty canvas (or `Reset highlight`) to clear.
- **External modules hidden by default** — modules whose source file isn't under the project root (stdlib, `Agda.Builtin.*`, anything declared in your `.agda-lib`'s `depend:` list) start unchecked in the sidebar, greyed out, and filtered out of the graph. Hit `Toggle externals` to show or re-hide them in bulk, or check individual rows to bring in just what you need.
- **Reveal-on-click navigation (`--lazy`)** — in lazy mode the page opens with only the entry-point module visible (the one you passed as the positional argument). **Single click** on a module reveals the next layer of its imports — just the modules it directly depends on, nothing else. **Double click** on a module additionally toggles its definitions (leaves). The graph grows one conservative step at a time so big projects stay legible. Externals stay hidden unless you toggle them in.
- **Module-tree sidebar** — collapsible folder tree keyed on the dotted-module hierarchy (`Protocol.Example.Properties.Liveness.Theorem3` is a chain of nested folders). Each folder gets a tri-state checkbox (checked / indeterminate / unchecked) that cascades visibility to the whole subtree, so you can hide e.g. all of `Algebra.*` with one click. The entry module's parent chain auto-expands on load, and search auto-expands every folder containing a match.
- **Sidebar** — `Expand all` / `Collapse all` toggle every module cluster; `Show all` / `Hide all` and per-module checkboxes drive the visibility filter; `Toggle externals` flips the visibility of every external in one click.
- **Cascade depth** — dropdown next to the visibility filter (`1` / `2` / `3` / `∞`, default `1`). Controls how many hops of dependencies each module-click reveals: `1` adds direct deps, `2` adds deps-of-deps, `∞` reveals the whole transitive closure (excluding externals). Useful when you want to skim a wide area without clicking every node.
- **Zoom controls** — `+` / `−` / `Fit` buttons in the sidebar. `Fit` reframes the viewport to the currently visible nodes (the layout-reshuffle and reveal-on-click flows already do this automatically).
- **Layout selector** — top of the sidebar. Choose **Force-directed** (default; cose, dynamic), **Grid** (compact, predictable), **Circle** (single-ring), **Concentric** (rings by node degree), or **Tree** (top-down, rooted at the active walker or the entry module). Re-layouts visible elements only — switching is fast even with thousands of total modules.
- **Spacing slider** — sits under the Layout dropdown. A single density factor (`0.3×`–`3.0×`, default `1.0×`) that multiplies cose's node repulsion / ideal edge length and the `spacingFactor` of the grid-like layouts, AND the radius of the ring that newly-revealed modules land in when you click. Pull the slider toward `0.3×` to keep clicks from blowing the view out — newly-revealed modules appear close to the source instead of at their initial-layout positions; nudge it up to `2×`+ if a dense subgraph is overlapping itself.
- **Display mode** — two buttons in the sidebar: **Dynamic** resets the view to only the entry module (the reveal-on-click default), **All modules** ticks every non-external module at once. Useful when you want a bird's-eye view, or when you want to start over.
- **Hide transitive edges** — sidebar checkbox. Hides every module-meta-edge `A → C` for which there's some other path `A → … → C` in the full module dependency graph. The transitive set is pre-computed by the Haskell backend at compile time (an IntSet-based reach+lookup pass over the module graph), so toggling the filter is essentially free. Useful on dense graphs like the Agda standard library where most imports are also reachable via several indirection layers.
- **Walker mode** — sidebar checkbox + Focus-depth dropdown (1 / 2 / 3) + Back button. When on, each tap on a module makes that module the "walker": the view collapses to just the walker plus its N-hop neighborhood (both incoming and outgoing), expands the walker's leaves, and re-layouts the focused subset so it fills the viewport at readable size. Useful for navigating large graphs one node at a time — instead of accumulating reveals, you "walk" from neighbor to neighbor. The Back button steps back through your walker history.

### Views

The HTML output ships several view variants — pick one with `--view=VIEW`. All views consume the same v2 `graph.json` schema; only the JS app + styling differ.

| View                      | What it does                                                              |
| ------------------------- | ------------------------------------------------------------------------- |
| `module-dag-pods` *(default)* | Top-down DAG of expandable module "pod" cards. Best for medium projects (≤ ~5k modules). dagre layout in-browser. |
| `cytoscape`               | Original cytoscape compound-node viewer (modules as parent boxes, defs inside). Force-directed; rich sidebar (search, walker, path mode, package layout, transitive-edge filter). |
| `sigma`                   | WebGL module-level renderer via sigma.js + graphology + dagre. Scales to ~1M nodes once edges stay thin. Layout selector (DAG / concentric) + 'fit' button + import / imported-by side panel. |
| `big-module-dag-pods`     | Viewport-virtualised port of `module-dag-pods` for ~100k modules. Layout is pre-computed Haskell-side; only pods in the visible viewport get DOM elements; a minimap drives navigation. |
| `ide-three-pane`          | File tree + focused subgraph + source pane. Definition-level.             |
| `source-centric`          | Code-first with a minimap. Definition-level.                              |
| `notion-doc`              | Scrollable cross-linked document. Definition-level.                       |
| `wiki-backlinks`          | Single-page focus with explicit depends-on / used-by lists. Definition-level. |
| `progress-dashboard`      | Grafana-style KPI board: completeness %, scoreboard (theorems-with-upstream-holes, avg-depth-unproven-leaf, postulate-debt ratio), D/P/H/F donut, hot-modules table, most-blocking-defs ranking, per-module hole-density calendar heatmap. Best first stop for the "is progress being made?" question. |
| `critical-path-holes`     | Kanban board of proof obligations. Surfaces holes/postulates upstream of the entry theorem, classified into Blocking-the-goal / Indirectly-blocking / Postulates / Recently-discharged lanes; cards carry severity, downstream-count, and the dep chain back to the goal. |
| `sunburst-hierarchy`      | D3 sunburst over the dotted-module hierarchy. Arc fill = weighted state mix; click to zoom. Toggleable import chords + A→B trail finder. |
| `pixel-grid-overview`     | Every def is a coloured tile. Per-module bands; sort modes (alpha / kind / deps / state); heatmap toggle (downstream / upstream / depth); keyboard cursor; minimap. Calendar-heatmap aesthetic. Inline mode only. |
| `reading-order-narrative` | Textbook-style scroll: defs in topological order, serif body with sticky margin mini-graph. Skim / 2nd-reading mode toggles; progress strip with hole/postulate hotspots. Pairs well with `--with-source`. |
| `cartographic-atlas`      | Topographic-map metaphor: continents (top-level module prefixes), territories (modules), elevation (depth from axioms), volcano/sinkhole glyphs for holes/postulates, ports = re-export sites, capital = entry theorem. Pan/zoom; trade routes on hover; weather report panel. |

For very large projects, start with `--view=big-module-dag-pods` (module-level scale) or `--view=sigma` (WebGL scale). For broken projects that don't type-check, combine any module-level view with `--skip-agda` for a sub-second render. For tracking proof completeness day-to-day, `--view=progress-dashboard` and `--view=critical-path-holes` are the most actionable.

```
cabal run agda-deps -- --format=html --view=sigma -i src/ -o out/ src/Main.agda
cabal run agda-deps -- --format=html --view=big-module-dag-pods --lazy -i src/ -o out/ src/Main.agda
cabal run agda-deps -- --format=html --view=module-dag-pods --skip-agda -i src/ -o out/ src/Main.agda
cabal run agda-deps -- --format=html --view=progress-dashboard -i src/ -o out/ src/Main.agda
cabal run agda-deps -- --format=html --view=critical-path-holes -i src/ -o out/ src/Main.agda
```

Or set the view once in `.agda-deps.yml`:

```yaml
format: html
view: sigma
lazy: true
```

and run plainly:

```
cabal run agda-deps -- -i src/ -o out/ src/Main.agda
```

### Custom palette

Override one or more of the state colors. Both DOT and HTML honor the same flags:

```
cabal run agda-deps -- --format=html \
  --color-defined=#0288d1 \
  --color-postulate=#d32f2f \
  --color-hole=#fbc02d \
  -i test/ -o test/ test/Test.agda
```

Hex values must match `#RRGGBB`; anything else aborts with a clear error.

## YAML config

`agda-deps` reads an optional YAML config from a project-local
dotfile or an explicit `--config=PATH`. Keys mirror the CLI flag names
in kebab-case (`--no-externals` ↔ `no-externals`). Merge order is
**defaults → config → CLI** — anything passed on the command line wins.

Discovery (first match wins):

1. `--config=PATH`.
2. `$AGDA_DEPS_CONFIG`.
3. `./.agda-deps.yml` (or `.yaml`).
4. Walk up from `cwd` to the first ancestor containing a
   `*.agda-lib` file; pick the dotfile there.

A stderr breadcrumb (`agda-deps: applied config from /abs/path/…`)
fires when a config applies, unless `--quiet`.

### `.agda-deps.yml`

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
color-postulate: "#f44336"
max-snippet-bytes: 1000000
json-mode: expanded
gzip: false
quiet: false
out-dir: build/deps
with-term-hashes: false       # emit per-def subterm fingerprints
min-term-depth: 3             # filter; ignored without with-term-hashes
with-signatures: false        # emit per-def rendered type signatures
normalise-signatures: false   # normalise types before rendering; needs with-signatures
signature-implicits: false    # show implicit args in signatures; needs with-signatures
```

Repeatable flags (`--exclude`, `--no-source-for`) take YAML lists.
Explicit `--color-*` CLI flags still win over `theme:`.

## Linking to source

Clicking a leaf node in the HTML graph can open that definition's Agda source code in a side drawer. Pass `--with-source` **together with `--lazy`** and the backend will, in the same run:

1. Invoke Agda's own HTML highlighter on every loaded module — same output you'd get from `agda --html`, including the semantic colouring that distinguishes `Datatype` / `Function` / `Postulate` / `Hole` / etc.
2. Read each definition's `.agda` source to locate the **paragraph** (run of non-blank lines) around its binding site.
3. Slice the matching span out of the highlighted HTML for that module and write it to a per-module `snippets/<Module>.json` bundle that the page fetches on demand.

`--with-source` needs `--lazy`: the snippet bundles are fetched at runtime, not baked into `deps.html`. Because the page uses `fetch()`, the output directory has to be served over HTTP:

```
cabal run agda-deps -- --format=html --with-source --lazy -i test/ -o test/ test/Test.agda
cd test && python3 -m http.server 8000   # then open http://localhost:8000/deps.html
```

Examples of what ends up in the drawer for the test corpus:

- Clicking `magic` (a postulate) shows:
  ```
  postulate
    magic : Nat
  ```
- Clicking `incomplete` (which has a hole) shows:
  ```
  incomplete : Nat → Nat
  incomplete n = ?
  ```
- Clicking `zero` (a constructor) shows the whole `data Nat : Set where ...` block.

All three render with Agda's own highlighting palette (inlined into the page), so `Datatype`, `Function`, `Postulate`, `InductiveConstructor`, `Hole`, etc. get their canonical colours.

Module clusters keep their click-to-collapse behavior; only leaf clicks open the drawer. If `--with-source` is omitted, the drawer is not used and clicking a leaf just highlights the neighborhood, as before.

No separate `agda --html` step is needed — the backend writes the per-module Agda HTML to a temp directory under `-o`, slices the snippets out, removes the temp dir, and emits the bundles under `snippets/`. Names whose source file isn't reachable at compile time (e.g., some builtin / synthetic names) simply have no snippet attached and show a small placeholder.

> `--with-source` requires `--lazy`: the snippet bundles are fetched at runtime. Passing it without `--lazy` prints a warning and renders without snippets. For *linked* rather than embedded source, see `--agda-html-dir` below (no `--lazy` needed).

### Opening the full `agda --html` page (`--agda-html-dir`)

`--with-source` *embeds* a per-definition snippet. Sometimes you want the **whole module page** instead — the real `agda --html` output, with Agda's own cross-reference links intact. If you've already run `agda --html`, point agda-deps at the result and the HTML views grow an **Open source** affordance instead of (or alongside) the embedded drawer:

```
agda --html --html-dir=out/html -i test/ test/Test.agda
cabal run agda-deps -- --format=html --view=sunburst-hierarchy --agda-html-dir=html -i test/ -o out/ test/Test.agda
cd out && python3 -m http.server 8000   # then open http://localhost:8000/deps.html
```

The path is interpreted by the browser **relative to the generated HTML file** — with `deps.html` at `out/deps.html` and the pages under `out/html/`, pass `--agda-html-dir=html`. Each module opens `DIR/<Module.Name>.html`, the filename `agda --html` writes. At module granularity no per-definition anchor is needed; the module name *is* the link.

This is wired into the **`sunburst-hierarchy`** view: in the right-hand *Leaves in focus* pane a module row opens its source on **click** (a `⌖` button takes over zoom; the wheel arcs still zoom), and a floating card plus the centre disc also carry an **Open source ↗** button. External / builtin modules (no local page) are suppressed. When `--agda-html-dir` is omitted the view behaves exactly as before. Best served over HTTP — a `window.open` to a sibling `file://` page can be blocked by the browser.

## Large projects: lazy output

For big codebases a single self-contained `deps.html` (graph data, and snippets if requested) has to load in full before anything appears. Pass `--lazy` to split the output into a small page shell and on-demand JSON — and note that `--with-source` *requires* `--lazy` for exactly this reason:

```
cabal run agda-deps -- --format=html --with-source --lazy -i src/ -o out/ src/Main.agda
cd out && python3 -m http.server 8000
# then open http://localhost:8000/deps.html
```

The resulting directory layout under `-o`:

```
deps.html              ← small shell (~22 KB), no inlined data
graph.json             ← module-level skeleton:
                       ·   modules: every module name
                       ·   moduleEdges: aggregated A→B pairs (compact arrays)
                       ·   moduleFiles: name → modules/<Module>.json  (the manifest)
                       ·   bundleFiles: name → snippets/<Module>.json  (only with --with-source)
modules/
  <Module>.json        ← that module's leaves + edges originating in it.
  detail-<hash>.json   ← fallback for modules with non-safe filenames.
snippets/
  <Module>.json        ← per-module snippet bundle, fetched on demand
  bundle-<hash>.json   ← fallback for modules with non-safe filenames
```

On page load, the shell only fetches `graph.json` and cytoscape renders ~N module boxes plus aggregated module-to-module edges. When you click a module, the page fetches `modules/<Module>.json` (cached), splices its leaf nodes into cytoscape, and re-routes the relevant edges — leaf-to-leaf where both endpoints' modules are expanded, leaf-to-module-parent otherwise. Module-meta-edges that have at least one expanded endpoint are hidden in favour of the more specific dynamic edges. Click again to collapse.

**Why HTTP?** Modern browsers block `fetch()` on `file://` URLs, so the lazy layout has to be served via a tiny static server. `python3 -m http.server` is enough; any static-file server works.

For reference, on a real-world project (~21k nodes, ~248k leaf edges, ~33k aggregated module-to-module edges, ~17k snippets), the module-split `--lazy` layout loads **~3.2 MB** initially (`deps.html` + `graph.json`) out of ~207 MB total on disk. The bulk of the on-disk size lives in per-module files (`modules/`, `snippets/`) fetched only when you open that module, so most users see much less than 3.2 MB over the wire.

## Running on your own code

Point `-i` at the include path that resolves your imports, and pass the top-level module as the positional argument. For a flat project:

```
cabal run agda-deps -- --format=html -i src/ -o out/ src/MyMain.agda
```

For a project that depends on the Agda standard library, add its `src/` to the include path:

```
cabal run agda-deps -- --format=html \
  -i src/ -i /path/to/agda-stdlib/src \
  -o out/ src/MyMain.agda
```

Definitions that come from imported libraries appear as their own module clusters in the output.

## Consuming the JSON output

`--format=json` ships in two shapes selected by `--json-mode`:

- **packed** (default) — the v2 wire format. Adjacency is CSR-packed; per-def state and module indices are base64-encoded `Int8` / `Int32` typed arrays. Optimal for projects with tens of thousands of nodes. Writing a consumer requires a base64 → typed-array decode pass. By default the packed `defs` object carries only `names` / `modules` / `states` / `x` / `y`; add [`--packed-analytical`](#backend-flags) to also emit the per-definition `kinds` / `lines` / `access` / `unsafe` (and `types` under `--with-signatures`, CSR-packed `subterm*` under `--with-term-hashes`) arrays, so a consumer keeps the size win without losing the analytical fields the expanded form has. A decoded packed-analytical graph is node-for-node identical to expanded (the `schema/packed_analytical_check.py` gate enforces this).
- **expanded** — the obvious shape: `definitions` as an array of `{id, name, module, state, kind, x, y}` records, `definitionEdges` and `moduleEdges` as arrays of qname / module-name pairs, plus a `reexports` array. No base64. Carries `"schemaVersion": 2` and `"mode": "expanded"` at the top level so downstream tools can recognise the shape. Best for small fixtures and ad-hoc tooling. Includes an optional `definitionEdgesProvenance :: [Provenance]` array, parallel to `definitionEdges`, tagging each edge as one of `signature | body | module-local | with | unknown` (`module-local` marks an edge into an anonymous-module-local helper — a `where`-block helper or a `module _ (…) where` parameterised-section member; it was named `where` before `nodeKeyVersion` 3); older JSON without the field still parses (the consumer falls back to `unknown` for every edge). Both packed and expanded forms also carry a `"producer"` string (the build fingerprint of the emitting `agda-deps` — version, git revision, build date, GHC) and a `"nodeKeyVersion"` integer (the node-naming convention version, for stale-cache detection); both are additive and optional, and absent `nodeKeyVersion` is read as `1`.

State letters: `D` (defined), `P` (postulate), `H` (hole), `F` (failed under `--keep-going` — module-level marker, no underlying definition).

Kind values (structural, derived from Agda's `theDef`): `function`, `projection`, `datatype`, `record`, `constructor`, `postulate`, `primitive`, `other`. Use these to filter without string-scraping qnames — e.g. record-field projections come out as `kind: "projection"` rather than needing a regex on `X._._._.foo` patterns.

Each definition also carries an optional `unsafe` array — the soundness escapes it uses **directly** (not transitively): `non-terminating` (a `{-# NON_TERMINATING #-}` function) and `trustme` (the body or type references `primTrustMe`). This is orthogonal to `state`: a def can be `state: "D"` and still carry an `unsafe` tag, so a graph-derived `agda --safe`-style audit can flag escapes that the 4-state colour alone misses (postulates are already `P`, unsolved holes `H`). Always computed (no flag); omitted per-def when empty, so escape-free corpora stay byte-identical. A `{-# TERMINATING #-}` marker is deliberately **not** surfaced — Agda's ordinary termination checker stamps every proven-terminating def the same way, so it can't be distinguished from a normal proof. Direct-use only: "this proof transitively rests on a `trustme`" is a consumer reachability query, not a producer field.

Alongside the per-def `unsafe` array, the top level carries an optional `moduleOptionEscapes` object — a map from module name to the file-level `{-# OPTIONS #-}` flags that make `agda --safe` reject it (`--type-in-type`, `--no-positivity-check`, `--rewriting`, `--injective-type-constructors`, …). Where `unsafe` is a *per-definition* escape, this is a *whole-module* one, so it lives at the top level, e.g. `"moduleOptionEscapes": { "Trusted.Base": ["--type-in-type"] }`. Read from each module's own `OPTIONS` pragma (not the fully-resolved option set), so a global `--lenient-imports` / `--allow-unsolved-metas` on the command line — or a library default — is not misattributed to every module. Only the safety-relevant flags are kept (the unconditional single-flag set of Agda's `unsafePragmaOptions`); only modules with at least one escape appear; the whole field is omitted when none does, so escape-free corpora stay byte-identical. Note the boundary: a per-block `{-# NO_POSITIVITY_CHECK #-}` (or `{-# TERMINATING #-}`) is a *declaration* pragma, not an `OPTIONS` pragma, so it is not surfaced here — only file-level `{-# OPTIONS #-}` escapes are.

`reexports` rows: `{ "from": "Prelude.Init", "to": "Data.Product", "names": ["Data.Product.Σ", …] }` — each row captures `open import to public` performed in module `from`. Names are fully-qualified (matching `definitions[].name`). Walked from Agda's `iScope` (`NameSpaceId.ImportedNS` and `PublicNS`) so it includes both plain public opens and re-exports through parameterised module applications. A row that used `renaming` additionally carries an optional `"renames"` object mapping each in-scope alias to the canonical fully-qualified name it resolves to (a member of that row's `names`), e.g. `open import M public renaming (merge to combine)` emits `"renames": { "combine": "M.merge" }`. The field is omitted when the row has no renamed entries, so rename-free output is unchanged.

The expanded form has a machine-readable JSON Schema (draft 2020-12) at [`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json). Validate any expanded `deps.json` with e.g. `pipx run check-jsonschema --schemafile schema/graph-v2-expanded.schema.json deps.json`; CI runs this on every build. Additive fields (`nodeKeyVersion`, `producer`, `definitionEdgesProvenance`, `definitionSubterm*`, `externals_summary`, `moduleOptionEscapes`, per-def `line`/`access`/`type`/`unsafe`) are optional, so older output still validates. The `packed` form is not schematised.

That schema file is the committed *oracle*, but it is not hand-maintained against the producer by inspection: the expanded wire shape is described once in Haskell (`AgdaDeps.Backend.Wire`), `agda-deps --emit-schema` regenerates the schema from that description, and CI fails if the regenerated schema diverges from the committed file (`schema/check_schema.py`). So the producer cannot gain or drop a field without the committed schema being updated in the same change — closing the silent-drift gap that open-`additionalProperties` validation alone leaves.

For `--lazy` HTML output, the on-disk file layout (`graph.json` + `modules/*.json` + `snippets/*.json`) is documented in [CLAUDE.md](CLAUDE.md#v2-graphjson-schema). The short version: `graph.json`'s `moduleFiles` map is the manifest — walk it to discover detail files, don't derive URLs from module names.

## What gets filtered out

To keep the graph readable, the backend ignores compiler-generated names: pattern-lambdas, `with`-generated helpers, Kan operations, inlined functions from instantiated modules, primitive functions without clauses, `PrimitiveSort`, `DataOrRecSig`, `GeneralizableVar`, and the `Agda.Primitive.Level` axiom. See `ignoreDef` in `src/AgdaDeps/Deps.hs` if you need to tweak this.

Edges *through* ignored defs are still preserved: when a kept def's body references a `with`-helper that in turn references a real target, the edge `kept-def → real-target` is reconstructed via a closure pass over the recorded out-edges of every ignored def. This means `using vqtc-b ← validBlockRQTC …` clauses produce the expected dependency on `validBlockRQTC` even though Agda elaborates them through intermediate `with-NNN` helpers. See `contractIgnoredEdges` in `src/AgdaDeps/Deps.hs`.

## Relevant links

- https://unimath.github.io/agda-unimath/VISUALIZATION.html

## AI Disclaimer

I used Claude Code to generate features on this project.
Most of them are just pocs to visualize and explore agda projects.
Feel free to edit them.
