# Examples

Runnable recipes for `agda-deps`. Full flag reference: [README.md](README.md).

`test/Test.agda` is the bundled fixture: a small multi-module corpus covering
every node state and edge shape. Larger examples use a generic
`path/to/your-project/…` — substitute your own include path and entry module.

## Setup

```bash
cabal build
mkdir -p out
```

`agda-deps` is an Agda `Backend`, so the command line follows Agda's shape:
`-i INCLUDE_PATH … <entry-module>`. When invoked through cabal, everything before
`--` is for cabal; everything after is for the backend and Agda.

## DOT output (default)

```bash
cabal run agda-deps -- -i test/ -o out/ test/Test.agda
dot -Tsvg out/deps.dot -o out/deps.svg
```

Right when the consumer is another graph tool (Graphviz, dot2tex, anything
reading `digraph` syntax).

## HTML output — hand the JSON to `agda-plotter`

HTML rendering lives in a separate executable that reads this graph and links
no Agda. Produce, then render:

```bash
cabal run agda-deps -- --format=json -i test/ -o out/ test/Test.agda
agda-plotter --view=module-dag-pods -o out/
xdg-open out/deps.html
```

`module-dag-pods` (the plotter's default) is a top-down DAG of expandable module
pods — the right start for projects under ~5k modules. `agda-plotter
--list-views` names the other thirteen; its README documents each one.

## JSON output — for downstream tooling

```bash
# Compact: base64 CSR. Right for huge graphs.
cabal run agda-deps -- --format=json --json-mode=packed -i test/ -o out/ test/Test.agda

# Expanded: arrays of records, no decoder needed.
cabal run agda-deps -- --format=json --json-mode=expanded -i test/ -o out/ test/Test.agda
```

`packed` (default) is the smaller of the two but needs a base64 + Int32-LE
decoder; use `expanded` to consume from Python / TypeScript / shell.

## `--no-externals` — drop stdlib from the graph

```bash
cabal run agda-deps -- --format=json --json-mode=expanded --no-externals \
  -i test/ -o out/ test/Test.agda
```

Strips every module outside the project root (`Agda.Builtin`, `Data`, …). Cleaner
than curating `--exclude` lists. The JSON keeps an `externals_summary` recording
what was dropped.

## `--keep-going` — survive type-check errors

```bash
cabal run agda-deps -- --keep-going -i test/ -o out/ test/Test.agda
```

Catches the `TCErr` and proceeds; failing modules surface as `F`-state markers.
Use when commits contain `?` holes, when onboarding a broken project, or when one
WIP module shouldn't hide the rest. Pair with `--lenient-imports` if Agda refuses
to *import* a module with open metas.

## `--skip-agda` — module-level graph, no type-checking

```bash
cabal run agda-deps -- --skip-agda --format=json -i test/ -o out/ test/Test.agda
agda-plotter --view=module-dag-pods -o out/
```

Scans `module …` / `import …` lines and emits a module-level graph in
milliseconds. Right when the project doesn't type-check, when you only care about
the module DAG, or for a 1M+ module corpus. No D/P/H classification and no
definition-level edges, so only module-level views have anything to draw.

## `--lazy` — a page that stays small at scale

```bash
cabal run agda-deps -- --format=json --lazy \
  -i path/to/your-project/ -o out/ path/to/your-project/Main.lagda.md
agda-plotter --view=big-module-dag-pods -o out/
cd out/ && python3 -m http.server 8000
```

`--lazy` splits the packed JSON into a module-level `graph.json` plus per-module
`modules/<M>.json` detail files, so the initial load stays small however big the
project is. `agda-plotter` sees the `modules/` directory and emits a page shell
that fetches on demand instead of a self-contained page. Lazy output **requires
HTTP serving** — browsers block `fetch()` on `file://`.

To read the actual source alongside the graph, generate Agda's own highlighted
pages and point the plotter at them:

```bash
agda --html --html-dir=out/html path/to/your-project/Main.lagda.md
agda-plotter --view=sunburst-hierarchy --agda-html-dir=html -o out/
```

## `--with-term-hashes` — subterm fingerprints

```bash
cabal run agda-deps -- --format=json --json-mode=expanded \
  --with-term-hashes --min-term-depth=3 \
  -i path/to/your-project/ -o out/ path/to/your-project/Main.lagda.md
```

Emits canonical-form hashes for every elaborated subterm. Off by default (adds a
Term walk, ~50–100% wire growth). `--min-term-depth=3` (the default) cuts trivial
`Var`/`Lit`/`Sort` noise; `1` disables the filter.

## `argUsage` — find arguments a definition never uses

No flag: it is always computed, and rides in expanded JSON on the definitions
that have something to report.

```bash
cabal run agda-deps -- --format=json --json-mode=expanded \
  -i test/ -o out/ test/Test.agda

python3 - <<'EOF'
import json
for d in json.load(open("out/deps.json"))["definitions"]:
    au = d.get("argUsage")
    if au and au["removable"]:
        print(d["name"], au["removable"], au.get("removableRequires", {}))
EOF
```

`removable` positions can lose the binder *and* the argument at every call
site; `erasable` ones are used only in types, so they are `@0` candidates
rather than removals. Indices count the definition's own binders (implicits
included) — not the sibling `type` string, which still shows the binders Agda
inherited from an enclosing section. Check `removableRequires` before editing:
a position listed there is only removable together with the ones it names.

## `--incremental` — cache per-module work across rebuilds

```bash
# First run: full work, writes out/.agda-deps-cache/. Later runs: unchanged
# modules served from cache, no-op rebuilds skip re-emitting output.
cabal run agda-deps -- --incremental --format=json --json-mode=expanded \
  -i path/to/your-project/ -o out/ path/to/your-project/Main.lagda.md
```

Two cache layers keyed on the interface hash: a **fragment cache** skips the
per-definition walk, and an **incremental-serialise** layer skips rewriting
unchanged output (whole file on a no-op; in `--lazy` mode, only changed
`modules/<M>.json`). Output is byte-identical. Disabled under `--keep-going`;
`--cache-dir=DIR` relocates the cache. The dominant warm rebuild cost is Agda's
own interface load, which a backend can't avoid.

## `--packed-analytical` — compact JSON without losing fidelity

```bash
cabal run agda-deps -- --format=json --json-mode=packed --packed-analytical \
  --with-signatures --with-term-hashes \
  -i path/to/your-project/ -o out/ path/to/your-project/Main.lagda.md
```

Adds the per-def analytical fields (kind, line, access, unsafe, unsolved-meta
count, type, subterm hashes) to packed's `defs` as base64 typed arrays, so a
downstream tool keeps packed's size win *and* expanded's fidelity — a decoded
graph is node-for-node identical to expanded. Off by default; only affects
`--json-mode=packed`. With `--lazy`, the `defs` object in every per-module
detail file carries the corresponding local arrays.

## A YAML config, checked before use

```bash
agda-deps --show-defaults > .agda-deps.yml   # seed (fully commented out)
agda-deps doctor                             # unknown keys, bad values, no-op combinations
agda-deps doctor --strict                    # as a CI gate: warnings fail too
```

Keys mirror the CLI flags in kebab-case; CLI flags still win. `doctor` runs no
Agda and needs no input module.

## Type abstraction reports

```sh
agda-deps --format=json --json-mode=expanded --with-type-terms \
  --with-signatures -i test-hardening/ -o /tmp/type-graph \
  test-hardening/type-terms.agda
agda-optimization type-patterns /tmp/type-graph/deps.json --min-owners=2
```

Use a larger graph for repeated predicates. `--with-signatures` is optional;
structural matching uses `typeTerms`. The consuming report separates
inherited contexts, retrieves existing type bodies and checks known module
cycles. A proposed abstraction still needs source review and Agda validation.
