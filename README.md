# agda-deps: an Agda dependency graph generator

`agda-deps` explores Agda projects and emits dependency graphs relating
definitions, postulates, and incomplete definitions/expressions plus their
relation.

It can write two things:

- a **JSON** artifact (see
  [Consuming the JSON output](#consuming-the-json-output)),
- a Graphviz **DOT** file, for a quick static picture.

Based on the dependency graph of libraries, we also built two other tools:

| Tool                                                                            | What it does                                                                                    |
|---------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| [`agda-plotter`](https://github.com/input-output-hk/agda-plotter)               | Renders the graph as an interactive HTML page.                                                  |
| [`agda-graph-explorer`](https://github.com/input-output-hk/agda-graph-explorer) | Unused-import analysis, graph-level optimisation analyses, and an MCP server for coding agents. |

For an interactive page, see the [`agda-plotter` README](https://github.com/input-output-hk/agda-plotter#readme).

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

## Backend flags

Everything after `--` is forwarded to the backend and to Agda's CLI.
Standard Agda flags are accepted — `-i DIR` (include path), `-l LIB`,
`--library-file=FILE`, `--no-libraries`, and the trailing positional module.
`--help` lists the backend's options; `--agda-help` shows Agda's.

There is one subcommand, `agda-deps doctor`, which checks the YAML config file
and exits, see [Checking a config](#checking-a-config-agda-deps-doctor).

- `-o DIR` / `--out-dir=DIR` — output directory (`deps.dot|json`). Without it,
  output goes to stdout; `--lazy` requires it. A value ending in
  `.json`/`.dot` also sets the format unless `--format` is given.
- `--format=dot|json` — output format (default `dot`).
- `--config=PATH` — load a YAML config. See [YAML config](#yaml-config).
- `--theme=default|light|dark|colorblind` — palette preset for the four state
  colours in DOT output.
- `--color-defined|postulate|hole|failed=#RRGGBB` — override a state colour
  (defaults `#4caf50` / `#f44336` / `#9c27b0` / `#ff9800`).
- `--keep-going` — don't abort on a type-check error: tag the failing module
  `failed` and emit whatever loaded, with def-level data for every module that
  elaborated.
- `--skip-agda` — don't invoke Agda; emit a module-level graph from a source
  scan (`module` / `import` lines). No definition graph, so
  only module-level views have anything to draw.
- `--lenient-imports` — forward `--allow-unsolved-metas` to Agda, for projects
  that deliberately commit `?` holes; combine with `--keep-going`. Under this
  flag a module with unsolved metas *succeeds* (they become `unsolved#meta.*`
  postulates). Agda applies the flag globally, so a `--safe` dependency (such
  as the standard library) rejects it with `[SafeFlagPragma]`; there, use
  `--keep-going` alone.
- `--resolve-deps` — constrain Agda's search path to the project's `.agda-lib`
  `depend:` closure (it expands to `--no-libraries -i DIR ...`). Use it when
  two registered libraries share a module name and Agda reports
  `[AmbiguousTopLevelModuleName]`. With no `.agda-lib`, or if resolution
  fails, it warns and leaves the arguments unchanged.
- `--no-externals` — drop everything outside the project root (nodes and edges).
  JSON keeps a top-level `externals_summary` of what was dropped.
- `--json-mode=packed|expanded` — the `--format=json` shape (default `packed`).
  See [Consuming the JSON output](#consuming-the-json-output).
- `--packed-analytical` — add the per-def analytical arrays (`kinds`/`lines`/
  `access`/`unsafe`/`unsolvedMetas`, plus `types` and subterm arrays when those
  are enabled) to packed, so a decoded packed graph is node-for-node identical
  to expanded. With `--lazy`, each module detail file carries its local slice.
- `--with-term-hashes` — emit a `Word64` fingerprint per definition subterm
  (`definitionSubtermHashes` + `definitionSubtermDepths`) in expanded JSON.
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

## YAML config

`agda-deps` reads an optional YAML config.
Keys mirror the CLI flags in kebab-case (`--no-externals` ↔ `no-externals`).
Merge order is **defaults → config → CLI**. Discovery (first match wins):
`--config=PATH`, `$AGDA_DEPS_CONFIG`, `./.agda-deps.yml` (or `.yaml`), then the
dotfile in the nearest ancestor with a `*.agda-lib`.

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

### Checking a config: `agda-deps doctor`

```
agda-deps doctor [--config=PATH] [--strict]
```

Resolves the config exactly as a run would, then reports what is wrong with it.
It catches the failures a config fails *silently*:

- **Unknown keys.** A misspelled key is ignored by the parser, so the setting
  just never applies.
- **Bad values.** A colour that isn't `#RRGGBB`.
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
warnings too, for use as a CI gate.

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
modules/<Module>.json  ← that module's leaves + edges, plus requested analytical arrays
                         (detail-<hash>.json for non-safe names)
deps.html              ← small shell, no inlined data   (written by agda-plotter)
```

Without `--lazy`, `--format=json` writes one `deps.json` and `agda-plotter`
inlines it into a self-contained page that opens straight off disk.

## Consuming the JSON output

`--format=json` ships in two shapes, selected by `--json-mode`:

- **packed** (default) — CSR adjacency; per-def state and module indices as
  base64 `Int8`/`Int32` arrays. `defs`
  carries `names`/`modules`/`states`/`x`/`y` unless
  [`--packed-analytical`](#backend-flags) adds the `kinds`/`lines`/`access`/
  `unsafe`/`unsolvedMetas` (and `types`/`subterm*`) arrays. Best for tens of
  thousands of nodes. Lazy detail files carry the same fields, locally indexed.
- **expanded** — arrays of records keyed by qname / module name, no base64.
  Carries `"schemaVersion": 2` and `"mode": "expanded"`. Best for small
  fixtures and ad-hoc tooling.

Both forms carry `"producer"` (build fingerprint) and `"nodeKeyVersion"` (node
naming convention, for stale-cache detection; absent reads as `1`).

### Expanded top-level fields

| Field                        | Contents                                          |
|------------------------------|---------------------------------------------------|
| `v`, `schemaVersion`         | both `2`. Refuse an unrecognised `v`.             |
| `mode`                       | `"expanded"`.                                     |
| `nodeKeyVersion`, `producer` | node-naming convention; build fingerprint.        |
| `modules`                    | every module in the graph, ascending.             |
| `entryModule`                | the module passed on the command line, or `null`. |
| `externalModules`            | subset of `modules` outside the project root.     |
| `failedModules`              | modules whose type-check failed (`--keep-going`). |
| `definitions`                | one record per definition — see below.            |
| `definitionEdges`            | `[source, target]` pairs of definition names.     |
| `definitionEdgesProvenance`  | parallel to `definitionEdges` — see below.        |
| `moduleEdges`                | `[importer, imported]` pairs of module names.     |
| `transitiveModuleEdges`      | the module edges implied by a longer path.        |
| `moduleFiles`                | module name → source path.                        |
| `sourceFiles`                | every scanned source path.                        |
| `reexports`                  | one row per `open import … public` — see below.   |

Optional top-level fields (`moduleOptionEscapes`, `unsolvedModules`,
`definitionSubtermHashes`, `definitionSubtermDepths`, `externals_summary`) are
described below and omitted when they carry nothing.

Each `definitions` record always carries `{id, name, module, state, kind, x, y}`,
plus — when known for that definition — `line`, `access` (`private` / `public`),
`type` (under `--with-signatures`), `unsafe`, `unsolvedMetas`, and `argUsage`.

- **State letters** — `D` defined, `P` postulate, `H` hole, `F` failed.
- **Kind** — `function`, `projection`, `datatype`, `record`, `constructor`,
  `postulate`, `primitive`, `other`. Filter on these instead of scraping qnames.
- **`unsafe`** — soundness escapes used *directly*:
  `non-terminating` (`{-# NON_TERMINATING #-}`) and `trustme` (references
  `primTrustMe`).
- **`unsolvedMetas`** — count of *silent* unsolved metavariables.
- **`argUsage`** — arguments the
  definition never actually uses.
- **`unsolvedModules`** — module → `{ "metas": [lines], "constraints": [lines] }`.
- **`moduleOptionEscapes`** — module → the file-level
  `{-# OPTIONS #-}` flags that make `agda --safe` reject it.
- **`moduleEffectiveOptions`** — module → the
  actionability-relevant options actually *in force*, currently `--erasure`
  alone.
- **`definitionEdgesProvenance`** — parallel to
  `definitionEdges`, tagging each edge `signature | body | module-local |
  unknown`.
- **`reexports`** — `{ "from", "to", "names": [...] }`,
  one per `open import … public`.
- **`externals_summary`** — under `--no-externals`, the
  modules that were dropped plus their postulates
  (`{ "modules": [...], "postulates_by_module": {...} }`).
- **`definitionSubtermHashes`** / **`definitionSubtermDepths`** — under `--with-term-hashes`, one array per definition, parallel to
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

I used Claude Code to generate features on this project.
Most are proofs of concept for visualizing and exploring Agda projects.


## Legal Disclaimer

*Important disclaimer & acceptance of risk*.
This is a proof-of-concept implementation that has not undergone security
auditing. This code is provided "as is" for research and educational purposes
only. It has not been subjected to a formal security review or audit and may
contain vulnerabilities. Do not use this code in production systems, or any
environment where security is critical, without conducting your own thorough
security assessment. By using this code, you acknowledge and accept all
associated risks, and our company disclaims any liability for damages or losses.
