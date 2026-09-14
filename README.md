# agda-deps: an Agda dependency graph generator

`agda-deps` is an Agda compiler backend that emits a dependency graph relating
definitions, postulates, and incomplete definitions/expressions — a quick
overview of the state of a library.

It writes two things:

- a stable **JSON** artifact, the v2 `graph.json` (see
  [Consuming the JSON output](#consuming-the-json-output)),
- a Graphviz **DOT** file, for a quick static picture.

Everything else reads the JSON:

| Tool | What it does |
| ---- | ------------ |
| [`agda-plotter`](https://github.com/input-output-hk/agda-plotter) | Renders the graph as an interactive HTML page — fourteen views, from module-DAG overviews to definition-level browsers. |
| [`agda-graph-explorer`](https://github.com/input-output-hk/agda-graph-explorer) | Unused-import analysis, graph-level optimisation analyses, and an MCP server for coding agents. |

Neither links Agda, so both build from Hackage in minutes. For an interactive
page, see [Rendering the graph](#rendering-the-graph).

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

For the JSON graph:

```
cabal run agda-deps -- --format=json -i test/ -o test/ test/Test.agda
# -> test/deps.json
```

For DOT:

```
cabal run agda-deps -- --format=dot -i test/ -o test/ test/Test.agda
dot -Tsvg test/deps.dot -o deps.svg
```

Run on your own code by pointing `-i` at the include path that resolves your
imports (repeat `-i` for the standard library) and passing the top module:

```
cabal run agda-deps -- --format=json -i src/ -i /path/to/agda-stdlib/src -o out/ src/MyMain.agda
```

## Rendering the graph

HTML output lives in [`agda-plotter`](https://github.com/input-output-hk/agda-plotter),
a separate executable that reads the JSON emitted above. It does not link Agda,
so it builds from Hackage in minutes.

```
agda-deps   --format=json -i src/ -o out/ src/MyMain.agda    # produce
agda-plotter --view=module-dag-pods -o out/                  # render -> out/deps.html
xdg-open out/deps.html
```

The default view is interactive: pan & zoom, expand/collapse module pods,
click a definition for a detail drawer, search modules and definitions,
re-layout, and an **Externals: on/off** toggle that hides everything outside
the project root (stdlib, `Agda.Builtin.*`, `depend:` libraries). Thirteen
other views cover module-DAG overviews, definition-level browsing, and
proof-progress dashboards; `agda-plotter --list-views` names them, and its
README documents each one.

For projects large enough that inlining the whole graph makes the page slow to
open, see [Large projects: lazy output](#large-projects-lazy-output).

## Backend flags

Everything after `--` is forwarded to the backend and to Agda's CLI. Standard
Agda flags are accepted — `-i DIR` (include path), `-l LIB`,
`--library-file=FILE`, `--no-libraries`, and the trailing positional module.
`--help` lists the backend's options; `--agda-help` shows Agda's.

There is one subcommand, `agda-deps doctor`, which checks the YAML config file
and exits — see [Checking a config](#checking-a-config-agda-deps-doctor).

- `-o DIR` / `--out-dir=DIR` — output directory (`deps.dot|json`). Without it,
  output goes to stdout; `--lazy` requires it. A value ending in
  `.json`/`.dot` also sets the format unless `--format` is given.
- `--format=dot|json` — output format (default `dot`).
- `--config=PATH` — load a YAML config. See [YAML config](#yaml-config).
- `--theme=default|light|dark|colorblind` — palette preset for the four state
  colours in DOT output. `default`/`light` is the standard palette; `dark` is
  `#81c784`/`#ef5350`/`#ba68c8`/`#ffb74d`; `colorblind` is
  `#1b9e77`/`#d95f02`/`#7570b3`/`#e7298a`. Explicit `--color-*` flags win.
  `agda-plotter` takes the same flags with the same defaults, so a DOT and an
  HTML rendering of one project can be made to agree.
- `--color-defined|postulate|hole|failed=#RRGGBB` — override a state colour
  (defaults `#4caf50` / `#f44336` / `#9c27b0` / `#ff9800`).
- `--keep-going` — don't abort on a type-check error: tag the failing module
  `failed` and emit whatever loaded, with def-level data for every module that
  elaborated.
- `--skip-agda` — don't invoke Agda; emit a module-level graph from a source
  scan (`module` / `import` lines). No definition graph and no D/P/H states, so
  only module-level views have anything to draw.
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

Output-shape flags:

- `--exclude=PREFIX` — repeatable. Drop modules named `PREFIX` or `PREFIX.*`
  and their edges (e.g. `--exclude=Agda.Builtin`).
- `--lazy` — JSON only: emit a module-level `graph.json` plus per-module
  `modules/<Module>.json` detail files instead of one `deps.json`. Requires
  `-o`. See [Large projects](#large-projects-lazy-output).
- `--gzip` — `--lazy` only: also write a `.gz` next to every emitted JSON file
  (the plain `.json` is still written).

Every run also scans sources for `module` / `import` declarations and unions
that module-level graph into the output, so modules that never type-checked
(under `--keep-going`) still appear with their import wiring.

## Node colours

The four state colours apply to DOT output here, and to HTML output in
`agda-plotter`, which takes the same flag names and the same defaults:

```
cabal run agda-deps -- --format=dot \
  --color-defined=#0288d1 --color-postulate=#d32f2f --color-hole=#fbc02d \
  -i test/ -o test/ test/Test.agda
```

They are not carried in `graph.json` — each renderer keeps its own copy — so
changing one here does not change what `agda-plotter` draws. Pass the same
flags to both, or set them once in a shared `.agda-deps.yml`.

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
format: json
json-mode: packed
theme: dark
color-defined: "#4caf50"   # quote colours: bare #… is a YAML comment
lazy: true
no-externals: true
incremental: true
exclude:
  - Agda.Builtin
  - Data
```

Repeatable flags (`exclude`) take YAML lists. Explicit `--color-*` CLI flags
still win over `theme:`. Run `agda-deps doctor` to check a file before relying
on it.

### Checking a config: `agda-deps doctor`

```
agda-deps doctor [--config=PATH] [--strict]
```

Resolves the config exactly as a run would, then reports what is wrong with it
— no Agda run, no input module. It catches the failures a config fails
*silently*:

- **Unknown keys.** A misspelled key is ignored by the parser, so the setting
  just never applies. `doctor` names it and suggests the closest real key.
- **Bad values.** A colour that isn't `#RRGGBB`, an unrecognised `format:` slug
  (with a did-you-mean), `exclude: Data` where a list was meant, a quoted
  `"true"`, a non-positive `min-term-depth`. Also the YAML trap of an unquoted
  `color-hole: #9c27b0`, which YAML reads as a comment, leaving the key null.
- **Combinations that do nothing.** `lazy` under `format: dot`, `cache-dir`
  without `incremental`, `min-term-depth` without `with-term-hashes`,
  `json-mode` under `format: dot`, `incremental` together with `keep-going`,
  and the rest.

```
$ agda-deps doctor
agda-deps doctor

  config     /home/me/proj/.agda-deps.yml
  origin     found in the nearest ancestor with a *.agda-lib (/home/me/proj)
  keys       6 set

  error    format: "jsonn" is not a recognised value
           fix: did you mean `json`? one of: dot, json
  warning  cache-dir: only locates the incremental cache, which is off
           fix: add incremental: true, or drop cache-dir

Summary: 1 error, 1 warning
```

Exit status is 1 when there is any error, 0 otherwise; `--strict` fails on
warnings too, for use as a CI gate. Warnings assume the config stands alone —
a CLI flag layered on top can legitimately rescue any of them.

## Large projects: lazy output

`--lazy` splits the JSON into a module-level skeleton plus per-module detail
files, so a renderer can load the shape of the project first and pull in
definitions only when they are asked for:

```
cabal run agda-deps -- --format=json --lazy -i src/ -o out/ src/Main.agda
agda-plotter --view=big-module-dag-pods -o out/
cd out && python3 -m http.server 8000     # http://localhost:8000/deps.html
```

Layout under `-o`:

```
graph.json             ← module-level skeleton:
                       ·   modules, moduleEdges (compact A→B pairs)
                       ·   moduleFiles: name → modules/<Module>.json  (the manifest)
modules/<Module>.json  ← that module's leaves + edges (detail-<hash>.json for non-safe names)
deps.html              ← small shell, no inlined data   (written by agda-plotter)
```

`--lazy` only splits the packed form; under `--json-mode=expanded` it is inert
and a single `deps.json` is written. It needs `-o`, and the resulting page
needs HTTP serving — browsers block `fetch()` on `file://`.

Without `--lazy`, `--format=json` writes one `deps.json` and `agda-plotter`
inlines it into a self-contained page that opens straight off disk.

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
  `{ "removable": [i…], "removableRequires": {…}, "occursInBody": [i…], "erasable": [i…], "arity": n, "syntacticArity": n, "partiallyApplied": true, "binders": {…} }`.
  Indices are telescope positions (0-based, implicits included, ascending)
  over the definition's *own* binders — not the enclosing section's, which
  Agda prepends internally. `removable` means the binder *and* the argument
  at every call site can go; `erasable` means the argument is used only in
  types, so it is an `@0` candidate rather than a removal. Not computed for
  projections, constructors, datatypes, records, postulates or primitives.
  Omitted entirely when there is nothing to report. Always computed — no
  flag.

  **The index space is the definition's own *reduced* telescope, and it can
  be longer than the signature line.** A type whose codomain only becomes a
  function after unfolding contributes positions with no written binder at
  all — `f : (A : Set) → Tracer A` with `Tracer A = ⋯ → ⋯ → A → A` reports
  `arity: 4` off one written binder. **`syntacticArity`** is how many
  positions are on the signature line, and is omitted when it equals
  `arity`; a position `>= syntacticArity` has no binder to strike out, and
  equivalently no `binders` entry.

  The verdict is *interprocedural*: an argument passed into a helper that
  discards it reads unused in the caller too. Deleting a binder changes the
  definition's type, so on anything exported it is an API change.

  `removable` is filtered to positions whose binder can *actually* be
  deleted: a position is dropped when its variable still occurs elsewhere in
  the type, or when removing it would leave an earlier **hidden** binder
  unsolvable (`typeOf : {A : Set} → A → Set` — the unused value argument's
  domain is the only place `A` occurs). Both filters only ever shrink the
  set. `erasable` is not filtered: it claims an `@0` candidate, not a
  removal.

  Three fields qualify a `removable` verdict rather than producing one.
  **`occursInBody`** lists the positions whose variable the elaborated body
  still mentions: the value is threaded into a callee that discards it, so
  the deletion has to reach that callee too, while a `removable` position
  *absent* from it is a purely local edit. An instance argument resolved by
  instance search counts — pair it with `binders[i].hiding == "instance"` for
  the shape that most often breaks a build. **`partiallyApplied`** is `true`
  when the definition is referenced somewhere in the graph with fewer
  arguments than it takes: used as a value, so its arity is its interface and
  no position is really removable. Both are omitted when empty.
  **`removableRequires`** maps a position to the
  others that must be deleted **with** it, since some removals are valid
  only as a set; it is omitted when every removal stands alone, and a
  position absent from it can be removed by itself.

  The indices do **not** index the sibling `type` string, which still shows
  the section-inherited binders — align against the source signature, and
  mind `syntacticArity`. For
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
  function after unfolding gets no entry at all. An *absent* entry means the
  position is past the signature line (`>= syntacticArity`); a *present*
  entry with no `name` is a binder that is written, spelled `_`. Neither is
  a default. A name containing a `.` (`A.a` above) is a binder Agda
  *inserted* by generalising a `variable` declaration — a written binder
  name can never contain `.`, so that is a reliable signal that the position
  has nothing on the signature line to edit.

  Under `--with-signatures` each entry also carries **`type`**: that
  binder's domain, reified in the context of the binders before it — the
  slice of the signature at that position, which the per-def `type` string
  cannot give you because it is not re-indexed onto the definition's own
  binders. Often the only usable label, since most reported positions are
  unnamed.
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
- **`moduleEffectiveOptions`** (top-level, optional) — module → the
  actionability-relevant options actually *in force*, currently `--erasure`
  alone. Read from the interface's effective options, so unlike
  `moduleOptionEscapes` it sees the `.agda-lib` `flags:` line and the command
  line — which is where such a flag normally lives. Gate advice on it:
  without `--erasure`, `@0` is `[AttributeKindNotEnabled]`, so every
  `argUsage.erasable` verdict in that module is un-appliable as configured.
  Omitted when no module enables one.
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
