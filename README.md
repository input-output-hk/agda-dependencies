# agda-deps: an Agda dependency graph generator plus visualisations

`agda-deps` is an Agda compiler backend that emits a dependency graph relating
definitions, postulates, and incomplete definitions/expressions — a quick
overview of the state of a library.

There are two visual outcomes:

- a Graphviz **DOT** file,
- an interactive **HTML** page, here we have several backends (see [views](#views)),

All outcomes are generated from a stable **JSON** artifact (see the v2
`graph.json` schema).

Each node is coloured by the state of its definition:

| State     | Colour            | Meaning                                              |
| --------- | ----------------- | ---------------------------------------------------- |
| Defined   | green `#4caf50`   | A function, datatype, record, or constructor.        |
| Postulate | red `#f44336`     | An `Axiom` / `postulate`.                            |
| Hole      | purple `#9c27b0`  | Contains an unsolved meta — a `?` or a silent one.   |
| Failed    | orange `#ff9800`  | Module whose type-check failed under `--keep-going`. |

## Prerequisites

- GHC, `base >= 4.10 && < 4.23`.
- `Agda >= 2.8 && < 3`.

## Build

Two builds, against Agda 2.8 (default) or 2.9:

```
cabal build                                                                        # Agda 2.8.0 (default)
cabal build --project-file=cabal.project.agda29 --builddir=dist-agda29 agda-deps   # Agda 2.9.0
```

## Quick start

For DOT generation:

```
cabal run agda-deps -- --format=dot -i test/ -o test/ test/Test.agda
dot -Tsvg test/deps.dot -o deps.svg
```

For HTML generation:

```
cabal run agda-deps -- --format=html -i test/ -o test/ test/Test.agda
xdg-open test/deps.html
```

The default view is interactive: pan & zoom, expand/collapse module pods,
click a definition for a detail drawer, search modules and definitions,
re-layout, and an **Externals: on/off** toggle that hides everything outside
the project root (stdlib, `Agda.Builtin.*`, `depend:` libraries). Other views
add their own controls — a file/module tree in `ide-three-pane` and
`notion-doc`, a transitive-edge filter in `sigma`.

Module pods start collapsed either way; under `--lazy` expanding one *fetches*
that module's definitions instead of reading them from the inlined graph.

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

There is one subcommand, `agda-deps doctor`, which checks the YAML config file
and exits — see [Checking a config](#checking-a-config-agda-deps-doctor).

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
  elaborated.
- `--skip-agda` — don't invoke Agda; render a module-level graph from a source
  scan (`module` / `import` lines). No definition graph, no
  D/P/H states, no snippets — module-DAG views only.
- `--lenient-imports` — forward `--allow-unsolved-metas` to Agda, for projects
  that deliberately commit `?` holes; combine with `--keep-going`. Under this
  flag a module with unsolved metas *succeeds* (they become `unsolved#meta.*`
  postulates), so `failedModules: []` alone does **not** mean "everything
  compiles" — check `unsolvedModules` and the per-def `unsolvedMetas` counts,
  which single out the *silent* metas (missing record fields, failed instance
  search, unsolved `_`) that plain `agda` would reject, while honest `?` holes
  stay plain state-`H` defs.
- `--resolve-deps` — constrain Agda's search path to the project's `.agda-lib`
  `depend:` closure.
- `--no-externals` — drop everything outside the project root (nodes and edges).
  JSON keeps a top-level `externals_summary` of what was dropped.
- `--json-mode=packed|expanded` — the `--format=json` shape (default `packed`).
  See [Consuming the JSON output](#consuming-the-json-output).
- `--packed-analytical` — add the per-def analytical arrays (`kinds`/`lines`/
  `access`/`unsafe`/`unsolvedMetas`, plus `types` and subterm arrays when those
  are enabled) to packed, so a decoded packed graph is node-for-node identical
  to expanded.
- `--with-term-hashes` — emit a `Word64` fingerprint per definition subterm
  (`definitionSubtermHashes` + `definitionSubtermDepths`) in expanded JSON. Off
  by default (adds a Term walk, ~50–100% wire growth).
- `--min-term-depth=N` — drop subterms below AST depth `N` (default `3`; `1`
  disables). Needs `--with-term-hashes`.
- `--with-signatures` — emit each definition's reified type as the per-def
  `type` field in expanded JSON (as written, one line). Off by default.
- `--normalise-signatures` — normalise types before rendering.
- `--signature-implicits` — show implicit/irrelevant args.
- `--incremental` — per-module caching under `<out-dir>/.agda-deps-cache/`
  (`./.agda-deps-cache/` with no `-o`), keyed on the interface hash. Disabled
  under `--keep-going`.
- `--cache-dir=DIR` — override the cache location.
- `--quiet` — suppress the progress lines on stderr; warnings and errors still
  print.
- `--version` / `-V` — print the build fingerprint (version, git rev, build
  date, GHC) and exit. `--numeric-version` prints just the number.
- `--emit-schema` — print the expanded `graph.json` JSON Schema and exit.
- `--show-defaults` — print a commented sample `.agda-deps.yml` (every option
  at its default, commented out) and exit. Seed a config with
  `agda-deps --show-defaults > .agda-deps.yml`. See [YAML config](#yaml-config).

HTML / source flags:

- `--with-source` — embed each definition's source snippet; clicking a leaf
  opens it in a side drawer. Requires `--lazy`.
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
- `--gzip` — `--lazy` only: also write a `.gz` next to every emitted JSON file
  (the page still fetches the plain `.json`).

Every run also scans sources for `module` / `import` declarations and unions
that module-level graph into the output, so modules that never type-checked
(under `--keep-going`) still appear with their import wiring.

## Views

Pick one with `--view=VIEW`. All views consume the same `graph.json`; only
the JS app and styling differ.

| View                          | What it does |
| ----------------------------- | ------------ |
| `module-dag-pods` *(default)* | Top-down DAG of expandable module "pods". Best for ≤ ~5k modules; dagre layout in-browser. |
| `cytoscape`                   | Force-directed compound-node viewer (modules as boxes, defs inside), rich sidebar. |
| `sigma`                       | WebGL module-level renderer (sigma.js + graphology + dagre), with a transitive-edge filter. The largest-scale option. |
| `big-module-dag-pods`         | Viewport-virtualised `module-dag-pods`; layout precomputed Haskell-side, minimap. Targets ~100k modules. |
| `ide-three-pane`              | File/module tree + focused subgraph + source pane. Definition-level. |
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

The quickest way to start is to generate a fully-documented sample — every
option at its default with a one-line comment — and edit it:

```
agda-deps --show-defaults > .agda-deps.yml
```

The generated file is entirely commented out, so it reproduces the defaults
as-is; uncomment only the keys you want to change.

```yaml
out-dir: build/deps
format: html
view: module-dag-pods
theme: dark
color-defined: "#4caf50"   # quote colours: bare #… is a YAML comment
lazy: true
with-source: true
no-externals: true
incremental: true
exclude:
  - Agda.Builtin
  - Data
```

Repeatable flags (`exclude`, `no-source-for`) take YAML lists. Explicit
`--color-*` CLI flags still win over `theme:`. Run `agda-deps doctor` to check
a file before relying on it.

### Checking a config: `agda-deps doctor`

```
agda-deps doctor [--config=PATH] [--strict]
```

Resolves the config exactly as a run would, then reports what is wrong with it
— no Agda run, no input module. It catches the failures a config fails
*silently*:

- **Unknown keys.** A misspelled key is ignored by the parser, so the setting
  just never applies. `doctor` names it and suggests the closest real key.
- **Bad values.** A colour that isn't `#RRGGBB`, an unrecognised `view:` slug
  (with a did-you-mean), `exclude: Data` where a list was meant, a quoted
  `"true"`, a negative `max-snippet-bytes`. Also the YAML trap of an unquoted
  `color-hole: #9c27b0`, which YAML reads as a comment, leaving the key null.
- **Combinations that do nothing.** `with-source` without `lazy`, `cache-dir`
  without `incremental`, `min-term-depth` without `with-term-hashes`, a `view:`
  under `format: dot`, `incremental` together with `keep-going`, and the rest.

```
$ agda-deps doctor
agda-deps doctor

  config     /home/me/proj/.agda-deps.yml
  origin     found in the nearest ancestor with a *.agda-lib (/home/me/proj)
  keys       6 set

  error    view: "sigmaa" is not a recognised value
           fix: did you mean `sigma`? one of: cytoscape, ide-three-pane, …
  warning  cache-dir: only locates the incremental cache, which is off
           fix: add incremental: true, or drop cache-dir

Summary: 1 error, 1 warning
```

Exit status is 1 when there is any error, 0 otherwise; `--strict` fails on
warnings too, for use as a CI gate. Warnings assume the config stands alone —
a CLI flag layered on top can legitimately rescue any of them.

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
splices in the leaves.

## Consuming the JSON output

`--format=json` ships in two shapes, selected by `--json-mode`:

- **packed** (default) — CSR adjacency; per-def state and module indices as
  base64 `Int8`/`Int32` arrays (consumers decode base64 → typed array). `defs`
  carries `names`/`modules`/`states`/`x`/`y` unless
  [`--packed-analytical`](#backend-flags) adds the `kinds`/`lines`/`access`/
  `unsafe`/`unsolvedMetas` (and `types`/`subterm*`) arrays. Best for tens of
  thousands of nodes.
- **expanded** — arrays of records keyed by qname / module name, no base64.
  Carries `"schemaVersion": 2` and `"mode": "expanded"`. Best for small
  fixtures and ad-hoc tooling.

Both forms carry `"producer"` (build fingerprint) and `"nodeKeyVersion"` (node
naming convention, for stale-cache detection; absent reads as `1`).

### Expanded top-level fields

| Field | Contents |
| --- | --- |
| `v`, `schemaVersion` | both `2`. Refuse an unrecognised `v`. |
| `mode` | `"expanded"`. |
| `nodeKeyVersion`, `producer` | node-naming convention; build fingerprint. |
| `modules` | every module in the graph, ascending. |
| `entryModule` | the module passed on the command line, or `null`. |
| `externalModules` | subset of `modules` outside the project root. |
| `failedModules` | modules whose type-check failed (`--keep-going`). |
| `definitions` | one record per definition — see below. |
| `definitionEdges` | `[source, target]` pairs of definition names. |
| `definitionEdgesProvenance` | parallel to `definitionEdges` — see below. |
| `moduleEdges` | `[importer, imported]` pairs of module names. |
| `transitiveModuleEdges` | the module edges implied by a longer path. |
| `moduleFiles` | module name → source path. |
| `sourceFiles` | every scanned source path. |
| `reexports` | one row per `open import … public` — see below. |

Optional top-level fields (`moduleOptionEscapes`, `unsolvedModules`,
`definitionSubtermHashes`, `definitionSubtermDepths`, `externals_summary`) are
described below and omitted when they carry nothing.

Each `definitions` record always carries `{id, name, module, state, kind, x, y}`,
plus — when known for that definition — `line`, `access` (`private` / `public`),
`type` (under `--with-signatures`), `unsafe`, `unsolvedMetas`, and `argUsage`.

- **State letters** — `D` defined, `P` postulate, `H` hole, `F` failed
  (module-level marker under `--keep-going`).
- **Kind** (from Agda's `theDef`) — `function`, `projection`, `datatype`,
  `record`, `constructor`, `postulate`, `primitive`, `other`. Filter on these
  instead of scraping qnames.
- **`unsafe`** (per-def, optional) — soundness escapes used *directly*:
  `non-terminating` (`{-# NON_TERMINATING #-}`) and `trustme` (references
  `primTrustMe`). Orthogonal to `state`. Omitted when empty. `{-# TERMINATING #-}`
  is not surfaced (indistinguishable from an ordinary proven-terminating def).
- **`unsolvedMetas`** (per-def, optional) — count of *silent* unsolved
  metavariables the def mentions directly (missing record fields, failed
  instance search, unsolved `_` — what plain `agda` reports as
  `UnsolvedMetaVariables`). Honest interaction `?` holes are *not* counted, so
  `H` with no `unsolvedMetas` = open goal(s) only; `H` with a count =
  silently-missing evidence. Omitted when 0. Only meaningful under
  `--lenient-imports` / `--allow-unsolved-metas` (without the flag such
  modules simply fail).
- **`argUsage`** (per-def, optional, expanded only) — arguments the
  definition never actually uses:
  `{ "removable": [i…], "removableRequires": {…}, "erasable": [i…], "arity": n, "binders": {…} }`.
  Indices are telescope positions (0-based, implicits included, ascending)
  over the definition's *own* binders — the ones on its signature line, not
  the enclosing section's, which Agda prepends internally. `removable` means
  the binder *and* the argument at every call site can go; `erasable` means
  the argument is used only in types, so it is an `@0` candidate rather than
  a removal. Not computed for projections, constructors, datatypes, records,
  postulates or primitives. Omitted entirely when there is nothing to
  report. Always computed — no flag.

  It is Agda's own positivity/polarity result, so it is *interprocedural*:
  an argument passed into a helper that discards it reads unused in the
  caller too. Deleting a binder changes the definition's type, so on
  anything exported it is an API change.

  `removable` additionally requires that the binder can *actually* be deleted:
  a position whose variable still occurs in the rest of the type is filtered
  out, even when Agda's verdict calls it unused. That matters for arguments
  used only at **irrelevant** positions (`.(p : A)`, or a relevant binder
  passed to a callee that consumes it irrelevantly) — Agda's own occurrence
  test ignores those, so without the filter such a binder looks removable and
  deleting it leaves the type naming something out of scope. `erasable` is not
  filtered: it claims an `@0` candidate, not a removal.

  Two things to get right. The indices do **not** index the sibling `type`
  string, which still shows the section-inherited binders — align against
  the source signature. And `removableRequires` maps a position to the
  others that must be deleted **with** it, since some removals are valid
  only as a set; it is omitted when every removal stands alone, and a
  position absent from it can be removed by itself. For
  `length : {a} {A : Set a} {n} → Vec A n → ℕ`:

  ```json
  "argUsage": {
    "removable": [0, 1, 3],
    "removableRequires": { "0": [1, 3], "1": [3] },
    "erasable": [], "arity": 4,
    "binders": {
      "0": { "hiding": "implicit", "name": "A.a" },
      "1": { "hiding": "implicit", "name": "A" },
      "3": { "hiding": "explicit" }
    }
  }
  ```

  — dropping the vector (3) alone is valid; dropping `A` (1) also forces 3;
  dropping the level `a` (0) forces both. Index 2 (`n`) is genuinely used
  and so is not listed at all.

  **`binders`** says how each *reported* position is written, so a report
  line can read `argument 0 ({A : Set})` instead of `argument 0` — the
  difference between a correct edit and deleting the wrong argument, since
  most reported positions are implicit or instance rather than explicit.
  Keyed like `removableRequires` (position as a decimal string), sparse, and
  read off the syntactic `Pi` spine — so `hiding` is always present
  (`explicit` / `implicit` / `instance`), `name` only when the binder has
  one (`Nat → Nat` names nothing), and a position whose type only becomes a
  function after unfolding gets no entry at all. An absent entry carries no
  information; it is never a default. A name containing a `.` (`A.a` above)
  is a binder Agda *inserted* by generalising a `variable` declaration —
  a written binder name can never contain `.`, so that is a reliable signal
  that the position has nothing on the signature line to edit.
- **`unsolvedModules`** (top-level, optional) — module →
  `{ "metas": [lines], "constraints": [lines] }` rollup of the same split:
  the source lines of each silent unsolved meta (one entry per meta) and of
  unsolved constraints. Modules whose only holes are honest `?`s don't
  appear; omitted when empty. Under `--lenient-imports` read this *alongside*
  `failedModules` — an empty `failedModules` with a non-empty
  `unsolvedModules` means "loaded, but with un-produced evidence".
- **`moduleOptionEscapes`** (top-level, optional) — module → the file-level
  `{-# OPTIONS #-}` flags that make `agda --safe` reject it (`--type-in-type`,
  `--no-positivity-check`, `--rewriting`, …). Read from each module's own
  `OPTIONS` pragma. Only safety-relevant flags; omitted when none.
- **`definitionEdgesProvenance`** (expanded, optional) — parallel to
  `definitionEdges`, tagging each edge `signature | body | module-local |
  unknown`. Absent falls back to `unknown`. There is no `with` tag: a dependency
  reached only through a `with`-abstraction arrives on the parent as `body`,
  because the helper's edges are contracted into it.
- **`reexports`** rows (expanded only) — `{ "from", "to", "names": [...] }`,
  one per `open import … public`; a row that used `renaming` also carries a
  `"renames"` map (`alias → canonical name`).
- **`externals_summary`** (top-level, optional) — under `--no-externals`, the
  modules that were dropped plus their postulates
  (`{ "modules": [...], "postulates_by_module": {...} }`).
- **`definitionSubtermHashes`** / **`definitionSubtermDepths`** (expanded,
  optional) — under `--with-term-hashes`, one array per definition, parallel to
  `definitions`.

The expanded form has a JSON Schema at
[`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json).
Validate with e.g.
`pipx run check-jsonschema --schemafile schema/graph-v2-expanded.schema.json deps.json`.
The wire shape is described once in `AgdaDeps.Backend.Wire`; `agda-deps
--emit-schema` regenerates the schema from it. The `packed` form is not
schematised.

## What gets filtered out

To keep the graph readable, the backend ignores compiler-generated names
(`ignoreDef` in `src/AgdaDeps/Deps.hs`): module-instantiation copies,
`variable`-block names, pattern-lambdas, `with`-helpers, Kan operations,
`{-# INLINE #-}` functions, clause-less primitives, `PrimitiveSort`,
`DataOrRecSig`, `GeneralizableVar`, and the `Agda.Primitive.Level` axiom.

Edges *through* ignored defs are preserved: when a kept def references a
`with`-helper that references a real target, the edge `kept-def → real-target`
is reconstructed by a closure pass (`contractIgnoredEdges`, same file).

## AI disclaimer

I used Claude Code to generate features on this project. Most are proofs of
concept for visualizing and exploring Agda projects. Feel free to edit them.
