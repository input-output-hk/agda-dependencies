# Examples

Runnable recipes for `agda-deps`. For full flag reference see
[README.md](README.md); for design rationale and the empirical evidence
behind the default values see [Changelog.md](Changelog.md).

Throughout, `test/Test.agda` is the small bundled fixture (one defined
function, one postulate, one hole — every state branch exercised). The
real-world corpus used to tune the defaults below was the reference corpus,
a ~21k-node Agda formalisation; the larger examples use a generic
`path/to/your-project/…`, so substitute your own project's include
path and entry module wherever you see it.

## Setup

```bash
cabal build
mkdir -p out
```

---

## `agda-deps` — Agda backend that emits a dependency graph

`agda-deps` is registered as an Agda `Backend`, so the command line
follows Agda's usual shape: `-i INCLUDE_PATH … <entry-module>`.
Everything before `--` (when invoked through cabal) is for cabal;
everything after is for the backend + Agda.

### DOT output (default)

```bash
cabal run agda-deps -- -i test/ -o out/ test/Test.agda
dot -Tsvg out/deps.dot -o out/deps.svg
```

DOT is the right output when the consumer is another graph tool
(Graphviz, dot2tex, anything that reads the `digraph` syntax). No
heuristics; the format is dictated by the tool you're piping into.

### HTML output — interactive viewer

```bash
cabal run agda-deps -- --format=html --view=module-dag-pods \
  -i test/ -o out/ test/Test.agda
xdg-open out/deps.html
```

**Default view: `module-dag-pods`.** Top-down DAG of expandable
module pods. Empirically the right starting view for any project
under ~10k modules — the dagre layout is informative without
overwhelming. Switch to:

- `--view=cytoscape` — the original force-directed compound-graph
  viewer. Use when you want a *single* canvas with everything visible
  rather than a layered hierarchy.
- `--view=sigma` or `--view=big-module-dag-pods` — WebGL-rendered;
  scales to 100k+ modules. The DAG variant uses Haskell-side
  pre-computed layout to avoid blowing up dagre in the browser.
- `--view=ide-three-pane` / `--view=source-centric` —
  definition-level views; needs `--with-source` to be useful.
- `--view=critical-path-holes` / `--view=progress-dashboard` —
  specialty views for in-progress proofs.

### JSON output — for downstream tooling

```bash
# Compact: base64-encoded CSR. Right for huge graphs.
cabal run agda-deps -- --format=json --json-mode=packed \
  -i test/ -o out/ test/Test.agda

# Expanded: arrays of records, no decoder needed.
cabal run agda-deps -- --format=json --json-mode=expanded \
  -i test/ -o out/ test/Test.agda
```

**Default mode: `packed`.** ~5× smaller than `expanded` on
large-scale projects (~21k defs). Switch to `expanded` when you
need to consume the JSON from Python / TypeScript / shell — the
`packed` form needs a base64 + Int32-LE decoder.

Downstream tooling generally requires `--json-mode=expanded`.

### `--no-externals` — drop stdlib from the graph

```bash
cabal run agda-deps -- --format=json --json-mode=expanded \
  --no-externals \
  -i test/ -o out/ test/Test.agda
```

Strips every module outside the project root (typically `Agda.Builtin`,
`Data`, `Function`, `Relation`, etc.). Cleaner than maintaining
`--exclude=PREFIX` lists. The JSON retains an
`externals_summary` field so downstream tooling that wants a diagnostic
record of the trusted base can still see what was dropped.

### `--keep-going` — survive type-check errors

```bash
cabal run agda-deps -- --keep-going \
  -i test/ -o out/ test/Test.agda
```

Default Agda behaviour aborts on any error. `--keep-going` catches
the `TCErr` and proceeds; failing modules surface as `F`-state
markers. Use when (a) commits deliberately contain `?` holes, (b)
you're onboarding a broken project, (c) one module's WIP shouldn't
hide the rest of the graph.

Pair with `--lenient-imports` if Agda refuses to *import* a module
with open metas (forwarded as `--allow-unsolved-metas`).

### `--skip-agda` — module-level graph, no type-checking

```bash
cabal run agda-deps -- --skip-agda --format=html \
  -i test/ -o out/ test/Test.agda
```

Doesn't invoke Agda at all. Scans `module …` / `import …` lines and
emits a module-level graph in milliseconds. Right when (a) the
project doesn't type-check at all, (b) you only care about the module
DAG (not definition states), (c) you're inspecting a 1M+ module
corpus that you can't afford to elaborate.

Trade-off: no defined/postulate/hole classification, no source
snippets, no definition-level edges.

### `--with-source` + `--lazy` — full HTML viewer at scale

```bash
cabal run agda-deps -- --format=html --view=ide-three-pane \
  --with-source --lazy \
  -i path/to/your-project/ \
  -o out/ path/to/your-project/Main.lagda.md

cd out/ && python3 -m http.server 8000
```

`--with-source` embeds each definition's Agda-highlighted source into
the page (clicking a leaf opens it in a side drawer). `--lazy`
splits the output into `graph.json` + per-module detail/snippet
files so the initial page load stays small. Lazy mode **requires
HTTP serving** — browsers block `fetch()` on `file://`.

**When to combine:** anything bigger than ~5k defs. Below that,
inline-HTML loads instantly.

### `--with-term-hashes` — round-6 P3 subterm fingerprints

```bash
cabal run agda-deps -- --format=json --json-mode=expanded \
  --with-term-hashes --min-term-depth=3 \
  -i path/to/your-project/ \
  -o out/ path/to/your-project/Main.lagda.md
```

Emits canonical-form hashes for every elaborated subterm into the
JSON. Off by default — adds a `Term` walk per definition and bloats
the wire format by ~50-100%.

**Default `--min-term-depth=3`** — empirically validated on the reference corpus.
At `1` (no filter) the cluster ranking is dominated by trivial
`Var`/`Lit`/`Sort` shapes; depth-3 cuts the hash volume ~3× (13.8M
→ 4.6M on the reference corpus) and pushes meaningful clusters to the top.
`--min-term-depth=1` is preserved for the launch behaviour.
