# Changelog

History of notable changes to `agda-deps`. Reverse-chronological. For
runnable recipes see [Examples.md](Examples.md); for forward-looking
work see [TODO.md](TODO.md); for deferred / refused ideas see
[Backlog.md](Backlog.md).

---

## 2026-06-13 — `agda-deps` — `--packed-analytical` (consumer-usable packed form)

The packed `graph.json` is ~5× smaller than expanded but, built for the
HTML viewer, its `defs` carried only `names`/`modules`/`states`/`x`/`y`
— omitting every per-definition analytical field the analysis consumers
need (`kind`, `line`, `access`, `type`, subterm hashes/depths). So a
consumer had to choose size *or* fidelity. `--packed-analytical` removes
the choice.

- **New arrays parallel to `defs.names`**, reusing the existing
  little-endian typed-array encoders (`AgdaDeps.Backend.Csr`, + a new
  `encodeWord64LE`): `defs.kinds` (Int8, enum `0..7`), `defs.lines`
  (Int32, `-1`=unknown), `defs.access` (Int8), `defs.types`
  (`[string|null]`, under `--with-signatures`), and CSR-packed
  `defs.subtermOffsets`/`subtermHashes` (Int64-LE)/`subtermDepths`
  (under `--with-term-hashes`). No edge/topology change — packed already
  carried CSR edges + provenance.
- **`access` is 3-valued** (`0`=unknown/absent, `1`=public, `2`=private),
  not the two values first proposed: the expanded form *omits* `access`
  for QNames with no local `ADDef` (external / dependency-only targets),
  and `0` round-trips to that omission so the two forms match exactly.
  (`line` uses `-1`, `type` uses `null` for the same reason.)
- **Shared lookups guarantee parity.** The per-QName
  kind/line/access/type/subterm lookups (`mkDefKind`/`mkDefLine`/… over
  the same `defsList`) are now a single source of truth used by *both*
  the expanded emitter (`toExpandedGraph`) and the packed-analytical
  arrays, so the node set and the per-node defaults can't drift. Kind
  Int8 encoding (`encodeDefKind`) matches `Wire.wireKind`'s ordering (and
  `FragmentCache.kindToInt`); a new `encodeDefAccess` sits beside the
  existing `encodeDefState`.
- **Off by default** (CLI `--packed-analytical` / YAML
  `packed-analytical:`); default packed output stays byte-identical, so
  HTML-viewer users are unaffected. Only meaningful with
  `--json-mode=packed` (expanded already carries everything).
- **Acceptance gate.** `schema/packed_analytical_check.py` decodes the
  packed arrays and asserts they equal the expanded form node-for-node
  (kind/line/access/type/subterm hashes); a CI step runs it (both sides
  cold-started, to avoid the warm-`.agdai` main-module skew). The
  Word64 subterm hashes are actually *more* faithful here than in
  expanded, which emits them as JSON numbers (exact only because the
  Haskell consumer parses via `Scientific`).
- **Consumer side** (sibling `agda-graph-explorer`) already documented
  the gap + a fixture and refuses today's packed; it can now add a
  base64-LE + CSR decoder mapping packed-analytical → its `ExpandedGraph`.

## 2026-06-13 — `agda-deps` — incremental serialise (P2), cache GC + `--cache-dir`, re-export-hub externals

Three follow-ups to the `--incremental` / `--no-externals` work.

### Incremental serialise (P2)

After the P1 fragment cache cut the per-definition /walk/, this cuts
the /serialise + write/ on a rebuild. New module
`AgdaDeps.SerialiseCache` (plain-text manifest in the cache dir; no
CPP — only the version-stable `hashString`):

- **Monolithic output** (`deps.json` / inline `deps.html`) is one blob
  whose slices can't be patched cheaply, so the win is the /no-op
  rebuild/: when nothing recompiled this run (every fragment hit —
  tracked by a new `recompiledRef`) and the output-context token
  (`outputToken`: module set + output-affecting options + build
  identity + `nodeKeyVersion`) is unchanged, the on-disk file is
  byte-identical, so generation /and/ write are skipped.
- **Lazy per-module files** (`modules/<M>.json`, `snippets/<M>.json`)
  each carry a content `mdjEpoch`/bundle epoch computed cheaply from
  the structured inputs (no base64, no JSON assembly), so a skipped
  file never forces its (lazy) content thunk. A body-only edit
  rewrites just the edited module's file; adding/removing a definition
  shifts the global node indices the per-module `outEdges` reference,
  so many epochs change (correct, if not minimal — truly minimal would
  need a stable-index lazy wire change, coordinated with the JS
  consumer).
- **Honest scope.** Profiling the warm rebuild on Jolteon-FastBFT
  (308 modules, 5862 defs) showed the dominant cost is **Agda's own
  interface load (~96 s)**, which a backend cannot avoid; the
  post-Agda aggregation (contraction over 734k edges, layout,
  classification) is ~40 ms, and serialise+write of the 12 MB lazy
  output is sub-second. So incremental serialise pays off where the
  /output/ is large relative to the graph — the monolithic expanded
  JSON with `--with-signatures --with-term-hashes` (≈150 MB; the
  daemon's config), `--with-source` snippet bundles — and on no-op
  rebuilds (skipping the re-emit + the mtime bump that a file-watcher
  would react to). It does not, and cannot, touch the Agda-load floor.
- Gated on `--incremental`; default output path is byte-identical.
  CI gains a no-op-skip / edit-detect / GC / lazy-no-rewrite step.

### Fragment cache GC + `--cache-dir`

- **GC.** After an `--incremental` run, `*.frag` files for modules no
  longer in the graph (deleted / renamed source) are pruned
  (`gcFragments`), keyed on the modules Agda processed this run.
  Failures are swallowed; only `*.frag` is touched.
- **`--cache-dir=PATH`** (CLI + YAML `cache-dir:`) overrides the
  default `<out-dir>/.agda-deps-cache` for both fragments and the
  serialise manifest.

### `classifyExternalModules` now sees re-export hubs

A stdlib module that only `open … public`s names from elsewhere
contributes no QName of its own, so it used to slip past
`--no-externals`. The re-export host + source module names
(`collectReExports` over the visited interfaces) are now pooled into
the classification input, so an out-of-root hub like `Data.List` is
seen and dropped. In-root hubs already carry an in-root signal, and
the `M.insertWith (||)` union keeps it. Additive: the test corpus has
no external re-export hub, so the golden is unchanged.

## 2026-06-12 — `agda-deps` — `--keep-going` hardening: a graph is always emitted

Closes the headline robustness gap (Backlog 2026-06-12): on a real
broken corpus the partial pass died with a bare **exit 120** and no
`deps.json`, blinding every downstream graph consumer the moment one
WIP module stopped type-checking.

- **Root cause found and fixed.** Exit 120 is Agda's
  `ImpossibleError`: `__IMPOSSIBLE__` is thrown as a *GHC exception*,
  not a `TCErr`, so every `catchError` guard in the partial driver was
  blind to it. The concrete trigger: TCM's `catchError` instance rolls
  the whole `TCState` back on a check failure, and
  `partialCompilerMain` re-merged only interface *signatures* —
  reification under `--with-signatures` then hit `infallibleSortKit`'s
  `fromMaybe __IMPOSSIBLE__` on the missing builtin bindings.
- **`mergeIfaceState`** now rebuilds the import state the way Agda's
  own (non-exported) `mergeInterface` does: signature + builtin
  bindings (with per-primitive rebinds) + remote meta store + pattern
  synonyms + display forms.
- **`catchAllTCM`** (TCErr *and* GHC exceptions; `ExitCode`/async
  re-thrown) now guards every stage of the partial pass — per
  definition, per module, per interface merge — so a broken piece is
  skipped with a breadcrumb instead of aborting; `preCompile` /
  `postCompile` failures print a diagnostic naming the stage before
  re-throwing, so an abort is never a silent exit code. A non-`TCErr`
  exception thrown *during* `check` itself is also caught and tagged
  now, not just `TCErr`s.
- **The partial pass no longer claims an entry module.** It used to
  pass `IsMain` to every module's hooks, so `entryModule` recorded
  whichever module was processed last (observed: a stdlib module).
  Under `--keep-going` with a failed entry the field is now absent.
- **Fixture + CI step** (`test-keepgoing/`, kept outside `test/` so
  the main corpus stays type-correct): entry imports one healthy and
  one failing module (instance-resolution error leaving unsolved
  metas, mirroring the Jolteon TestTrace failure); CI asserts
  `deps.json` is produced with the sibling's defs/edges/signatures and
  `failedModules == ["Broken"]`, under the full agda-explore daemon
  flag set.
- **Validated at scale** on the Jolteon-FastBFT corpus with a
  deliberately broken `TestTrace`: exit 0, 4841 defs (4533 with
  signatures), 703k edges, broken module tagged — where the same run
  previously produced nothing.

## 2026-06-12 — `agda-deps` — `--incremental`: per-module fragment cache

Implements P1 of the incremental-rebuild design (TODO.md): the
dominant rebuild cost (~79 % of a full run on a 16k-def corpus) is the
per-definition backend walk, re-run for *every* module on every
rebuild even when nothing changed.

- **`AgdaDeps.FragmentCache`** caches, per module, what
  `postModuleAD` returns (defs *including* dead-private extras) plus
  the module's contributions to the two compile-time side-channels
  (ignored edges, instance-method providers) — a `Skip`ped module
  never runs `compileDef`, so without those slices contraction would
  silently lose edges through its helpers. The slices are exact
  **before/after deltas** (`moduleSetup` snapshots the refs into
  `ModuleEnv`): the first cut filtered by module-name prefix, which
  missed defs Agda homes in *anonymous* modules (bare `_.…` /
  prefixless copies from `module _ ⦃ asm ⦄ where open … public`
  blocks) — on Jolteon, 21 such helpers carried ~12k contracted edges
  that an all-cache-hit run silently dropped. Fragment format v2;
  v1 fragments are auto-invalidated.
- **Key:** `(fragment format version, content-option fingerprint,
  iFullHash, nodeKeyVersion)`. `iFullHash` folds in the transitive
  imported-interface hashes, so a dependency change invalidates
  exactly the affected cone. Rendering-only options are excluded from
  the fingerprint.
- **Flow:** `moduleSetup` (preModule) returns `Skip cachedFragment` on
  a hit; `postModuleAD` writes fragments — imported modules
  unconditionally (their output is a pure function of the pruned
  interface, fresh or warm), the **main module only from a fresh
  check** (its output is enriched by the `getSignature` dead-private
  recovery, which a warm load can't see). A fragment hit therefore
  serves the *complete* main-module variant even on warm runs —
  `--incremental` normalises the warm-`.agdai` edge loss instead of
  inheriting it.
- **Serialisation:** Agda's own `EmbPrj` machinery, so `QName`s
  (NameIds, binding-site ranges) round-trip exactly and downstream TCM
  lookups on decoded names just work. The byte layer is only exposed
  by Agda ≥ 2.9; on 2.8 the flag degrades to a warning + no caching.
- **Surface:** `--incremental` / YAML `incremental: true`. Fragments
  live under `<out-dir>/.agda-deps-cache/`. Disabled under
  `--keep-going` (a failed module breaks the closed-cone invariant).
  Cache misses, corrupt fragments, and write failures all degrade to
  recompute/breadcrumbs, never an abort.
- **CI:** cold-write + warm-hit runs must emit byte-identical JSON and
  match the golden.

## 2026-06-12 — `agda-deps` — golden snapshot regenerated from a cold run

The committed golden had been generated from a warm-`.agdai` working
tree, freezing the *degraded* main-module variant (missing
`Test.Int-0`-class pattern-helper edges/kinds/types — the
"warm-`.agdai` edge loss"). CI only stayed green because its expanded
run happened to be the fifth corpus invocation, hence equally warm.
The golden is now the cold (complete) variant, and CI clears `.agdai`
before the runs that feed the golden check, making the comparison
deterministic. The warm-loss itself also turns out to be a
**main-module-only** phenomenon: imported modules' emission is a pure
function of their already-pruned interface, cache-state independent.

## 2026-06-12 — `agda-deps` — expanded-graph invariants + golden snapshot (phase 3)

- **`toExpandedGraph :: GraphInput -> ExpandedGraph`** extracted from
  `buildExpandedJson` (now a thin validate-then-encode wrapper).
- **`Wire.validateExpanded`** asserts the structural invariants JSON
  Schema can't express — `definitionEdgesProvenance` length == edges,
  `definitionSubterm{Hashes,Depths}` length == definitions, and every
  edge endpoint names a definition. They hold by construction, so
  `buildExpandedJson` `error`s on a violation (a regression assertion,
  not user-facing).
- **Golden snapshot guard.** `test/golden/expanded.golden.json` +
  `schema/golden_check.py` catch *content* regressions (states, kinds,
  edges, provenance, subterm hashes) the schema can't — the normaliser
  strips build/layout/path-volatile fields (`producer`, per-def `x`/`y`,
  absolute paths → sorted basenames) so it's portable across CI. A new
  CI step diffs the freshly-generated expanded output against it.
- Output remains byte-identical (phase 3 is a refactor + new guards).

## 2026-06-12 — `agda-deps` — expanded emission routed through the schema source of truth (phase 2)

Completes the single-source design: the expanded `graph.json` is now
*encoded* from the same `AgdaDeps.Backend.Wire` field tables that
generate the schema, so the gap is closed by construction.

- **`buildExpandedJson` builds an `ExpandedGraph` and calls
  `encodeExpanded`** (`= encodeObject expandedFields`). Each field table
  row carries the wire name, schema fragment, and byte encoder together,
  so a field cannot be emitted without appearing in the generated schema
  (and the CI oracle check forces the committed schema to match). The
  old hand-rolled per-field string assembly (`defJson`, `pairJson`,
  `provJson`, `reExportsArrayJson`, the subterm-array fields) is gone.
- **`Wire` now owns the expanded wire tags** (`wireState` / `wireKind` /
  `wireAccess`); the duplicate `stateLetter` / `kindTag` / `accessTag` /
  `provJson` in `GraphJson` were removed.
- **Output is byte-identical.** Verified against goldens from the
  pre-reroute emitter across `default`, `--with-signatures
  --with-term-hashes`, `--no-externals`, and `--keep-going` on the test
  corpus — every byte matches. `packed` mode and `--lazy` are untouched
  (still hand-rolled in `GraphJson`).

## 2026-06-12 — `agda-deps` — expanded-schema single source of truth + drift check (phase 1)

Closes the silent-schema-drift gap: open `additionalProperties` meant a
new producer field could slip past JSON-Schema validation undocumented.

- **`AgdaDeps.Backend.Wire`** describes the v2 *expanded* wire shape
  once (field tables + a small `SchemaDoc` ADT mirroring the committed
  schema's `$defs`).
- **`agda-deps --emit-schema`** prints the JSON Schema generated from
  that description (no Agda run / input file needed).
- **`schema/check_schema.py`** + a CI step diff the generated schema
  against the committed `schema/graph-v2-expanded.schema.json`
  *structurally* (ignoring `description`/`$id`/`$schema`/`title`,
  sorting `required`/`enum`). The committed file stays a frozen oracle
  — never overwritten; a wire-shape change must update it deliberately
  in the same change, so the check fails on drift. (The existing
  `check-jsonschema` conformance run is unchanged.)
- Phase 1 is schema-only and adds **no** new runtime fields and does
  **not** reroute emission, so `graph.json` output is byte-identical.
  Phase 2 will route `buildExpandedJson`'s encoding through the same
  `Wire` field tables (emitted-bytes ≡ schema by construction).

## 2026-06-12 — `agda-deps` — `--version` reports the build fingerprint; install recipe

Closes the "which build is this?" / stable-binary-path item from the
Jolteon usage analysis (~30 transcript Bash calls were binary
archaeology).

- **`--version` / `-V` now print the full build fingerprint** — version
  + git revision + build date + compiling GHC, the same string stamped
  into `graph.json` as `"producer"`. Previously `--version` printed only
  the bare semver (`agda-deps 1.1`), despite the docs claiming otherwise,
  so identifying a binary still required `mtime`-vs-`git log` forensics.
  `--numeric-version` is unchanged (bare `1.1`) for tooling that parses
  it.
- **Documented `cabal install` recipe** (README *Install a stable
  binary*, CLAUDE.md *Build / run*): `cabal install exe:agda-deps
  --overwrite-policy=always` puts a stable binary on `PATH` so callers
  stop hunting under `dist-newstyle/`.
- **`AGDA_DEPS_GIT_REV` override** for `BuildInfoTH`. `cabal install`
  builds from an sdist with no `.git`, so the TH git splice otherwise
  reports `git unknown`; the env var lets an installer stamp the commit
  (`AGDA_DEPS_GIT_REV=$(git rev-parse --short=12 HEAD) cabal install …`).
  In-tree builds (`cabal build` / `cabal run`) are unaffected — git wins
  when present, so the fingerprint stays byte-identical there.

## 2026-06-05 — `agda-deps` — build provenance stamped into `graph.json`

- **Build fingerprint baked into every binary (`BuildInfo`).** A new
  module captures the package version, the git revision (best-effort, `+`
  for a dirty tree), the compile date, and the compiling GHC at build time
  (TH for git, CPP for the date). `agda-deps --version` reports it, so
  "which build is this?" is one call instead of `ps` + `/proc/<pid>/exe`
  + `git log`.
- **Graph provenance stamped into `graph.json`.** Both the packed and
  expanded emitters now write `"producer"` (the build fingerprint) and
  `"nodeKeyVersion"` (the node-key convention version). Additive,
  optional fields; older readers ignore them, older JSON parses with
  `nodeKeyVersion` defaulting to `1`.

## 2026-06-05 — `agda-deps` — same-named helpers no longer collapse (E1 node collision)

A re-test against the reference corpus surfaced a high-severity producer
bug. Validated end-to-end (collision fixture, all output formats).

- **Same-named `where`/anonymous-module helpers no longer collapse.**
  Node identity now keys on `nodeKey`: `prettyShow` for top-level names
  (unchanged), plus a `@<binding-line>` suffix for `._.`-marked helpers,
  which `prettyShow` otherwise renders identically across every same-named
  helper in a module (so the last one won and the rest's edges vanished).
  The binding-site line is the one per-helper coordinate stable across
  signature sources — `NameId` is not, which is why the long-standing
  `hashQName = prettyShow` invariant existed; the line suffix keeps that
  property while disambiguating. `hashQName`, the expanded/packed wire
  `name`, and edge endpoints all derive from `nodeKey`, and the
  expanded-edge filter resolves by canonical string (not `QName` `Ord`),
  so distinct helpers stay distinct nodes and their edges resolve.
  Top-level node keys, and therefore default output for collision-free
  corpora, are byte-identical. Regression baked into `test/Test.agda`
  (via `test/Collision.agda`): `useA ⇝ QED@20 ⇝ targetA` and
  `useB ⇝ QED@26 ⇝ targetB` both survive.

## 2026-06-05 — `agda-deps` — opt-in normalised / implicit signatures

- **`--normalise-signatures`** reduces each type to its semantic form
  before reifying; **`--signature-implicits`** shows implicit/irrelevant
  arguments (named to avoid clashing with Agda's own `--show-implicit`).
  Both default off, so default `--with-signatures` output is
  byte-identical.

## 2026-06-04 — `agda-deps` — rendered type signatures (`--with-signatures`)

`agda-deps --with-signatures` renders each definition's type — `prettyTCM`
(reify) of `defType` in `compileDefAD`, *not normalised*, with Agda's
default printing (no `--show-implicit`), collapsed to one line — and emits
it as the optional per-def `"type"` field in expanded JSON. Additive:
default output is byte-identical (the field is absent without the flag).
Mirrored in YAML as `with-signatures` and threaded through
`Options`/`Config`/`NFData`.

---

## 2026-06-01 — `agda-deps` — `--agda-html-dir` + sunburst "Open source"

New flag `--agda-html-dir=DIR` links the HTML views to the pages
`agda --html` already wrote, rather than (or alongside) embedding
snippets with `--with-source`. The value is emitted into every view's
data-loading prelude as the `AGDA_HTML_BASE` JS var (trailing-slashed,
or `null` when the flag is absent), interpreted by the browser relative
to the generated HTML file. Plumbed the same way as every other flag:
`Options.optAgdaHtmlDir` + parser + `commandLineFlags` entry +
`Config.hs` kebab-case mirror (`agda-html-dir`) + `NFData`. Threaded
through `renderHtml` / `renderLazyHtml` / `renderHtmlFromInput` /
`htmlTemplate` / `dataLoadingPrelude` (and the `--skip-agda` HTML path).

First consumer: the **`sunburst-hierarchy`** view. At module
granularity the link needs no
char-offset anchor — the filename is just `<Module.Name>.html`. When
`AGDA_HTML_BASE` is set, a *Leaves in focus* row opens its module's
source on click, a `⌖` button takes over the (now-secondary) zoom, the
wheel arcs still zoom, and a floating card + the centre disc carry an
**Open source ↗** button; external / builtin modules are suppressed.
Everything is gated on `AGDA_HTML_BASE`, so output is unchanged when the
flag is absent.

---

## 2026-05-29 — `agda-deps` — `--lenient-imports` docs, `--resolve-deps`, partial `--keep-going` emission

### `--lenient-imports` × `--safe` incompatibility documented

`--lenient-imports` is implemented as an argv rewrite to Agda's
global `--allow-unsolved-metas`; any `--safe` module in the dep
closure (including stdlib) rejects it with `[SafeFlagPragma]`.
Per-module hole tolerance would require an upstream Agda change.
Documented the incompatibility prominently in both `--help`
(`src/AgdaDeps/Backend.hs`) and README, recommending
`--keep-going` alone for safe-stdlib projects.

### `--resolve-deps` flag

Opt-in resolution of the project's `.agda-lib` `depend:` closure
into an explicit `--no-libraries -i <dir> -i <dir> ...` argv
expansion. Use case: when multiple versions of the same library
are registered (e.g. both `standard-library-2.2` and
`standard-library-2.4`), Agda's resolver picks ambiguously and
produces `[AmbiguousTopLevelModuleName]` on a plain
`open import Level`. `--resolve-deps` reads `~/.agda/libraries`
(or `$AGDA_DIR/libraries` / `$XDG_CONFIG_HOME/agda/libraries`),
walks the transitive `depend:` closure, and pins the include
dirs explicitly.

New module `AgdaDeps.LibResolve` (parser for `.agda-lib` files,
registry loader, closure walk). Wired through `Main.hs` between
project-root discovery and `runAgdaArgs`. Mirrored in YAML as
`resolve-deps: true`. Falls back silently (with a stderr
breadcrumb) if there's no `.agda-lib` or any dependency can't
be resolved — manual `--no-libraries -i …` still works as a
workaround.

### Partial def-level emission under `--keep-going`

`AgdaDeps.ModuleExplorer.partialCompilerMain`
previously called `postCompile backend env isMain Map.empty` on
the failure branch, so when a downstream module fatally failed,
**all** def-level data from successfully-loaded modules was
discarded — the output graph collapsed to module-level only,
even if 100+ modules had elaborated cleanly. Two fixes:

1. **`catchError` now also wraps `setup`**, not just
   `check mainFile`. Any `TCErr` raised before `check mainFile`
   starts (e.g. `OptionError`, `SafeFlagPragma`,
   `AmbiguousTopLevelModuleName` from library resolution) is
   caught and reported via `reportFailed` instead of escaping.
2. **The failure branch now re-drives `preModule → compileDef
   → postModule` per decoded module**, accumulating per-module
   results into a `Map TopLevelModuleName mod` that's handed to
   `postCompile`. Each module's hooks are wrapped in
   `catchError` so one broken module is skipped (with a stderr
   breadcrumb) rather than aborting the partial pass.

Subtle load-bearing piece: before the per-module loop, every
decoded interface's `iSignature` is merged into `stImports` and
`stSignature` is cleared. Without this, downstream
`getConstInfo` calls in `contractIgnoredEdges` fail with
`Unbound name` panics for cross-module dep edges. Also covered
by the merge: avoiding `__IMPOSSIBLE__` "ambiguous name" trips
when the stale post-failure `stSignature` and the freshly-
merged imports both carry the same qname.

Verified on a synthetic 5-module corpus with one deliberately
broken dependency: old behaviour emitted 0 defs from 4 loaded
modules; new behaviour emits 20 defs from those same 4 modules
plus the failing module tagged in `failedModules[]`. Normal
(no-failure) mode is byte-identical against the existing
`test/` corpus.

---

## 2026-05-29 — `agda-deps` — remove the 14 view-shortcut boolean flags

Drop the deprecated per-view shortcut flags (`--cytoscape`,
`--sigma`, `--module-dag-pods`, `--ide-three-pane`,
`--source-centric`, `--notion-doc`, `--wiki-backlinks`,
`--big-module-dag-pods`, `--critical-path-holes`,
`--progress-dashboard`, `--cartographic-atlas`,
`--sunburst-hierarchy`, `--reading-order-narrative`,
`--pixel-grid-overview`). Deprecated 2026-05-27; passing one now
errors out as an unrecognised option. The replacement remains
`--view=NAME` (or `view: NAME` in `.agda-deps.yml`).

Removal touches:

- `commandLineFlags` in `src/AgdaDeps/Backend.hs` — the 14 `Option`
  entries.
- `src/AgdaDeps/Options.hs` — drop `setViewOpt`, `setViewShortcutOpt`,
  and the `optSawViewShortcut` field on `Options`. `NFData Options`
  shrinks by one slot. The `View` ADT, `viewSlug`, and `viewOpt`
  parser (which backs `--view=NAME`) stay.
- `src/Main.hs` — drop the one-time stderr deprecation note and the
  argv scan that drives it (`viewShortcutFlags`,
  `viewShortcutDeprecationNote`); drop the now-unused `System.IO`
  import.
- `README.md` — collapse the Views table to a single column; drop the
  "(Each view used to have a matching `--<slug>` shortcut flag …)"
  parenthetical on the `--view=VIEW` CLI bullet.
- `src/AgdaDeps/templates/views/module-dag-pods.html.tmpl` — rewrite
  the two stale `--big-module-dag-pods` mentions in the scale-warning
  overlay to `--view=big-module-dag-pods`.

`src/AgdaDeps/Config.hs` carried no per-view shortcut keys (YAML only
ever exposed `view: NAME`), so no changes were needed there.

---

## 2026-05-28 — `agda-deps` — round-6 P3 (AST subterm fingerprinting)

Round-6 follow-up to the proof-simplification proposal — specifically
P3 (AST-level subterm fingerprinting). Cross-file CSE /
lemma-extraction candidate detection over canonicalised internal
`Term`s. Three commits (`729ac07`, `16bef93`, `b546f1e`)
landed iteratively, each driven by empirical results on the
reference corpus pre-Wave-2A snapshot.

- **`AgdaDeps.TermCanon`** — new module. Canonical-form byte
  encoder for `Agda.Syntax.Internal.Term`. Two terms produce the
  same `Canonical` (and therefore the same 64-bit hash) iff they
  are alpha-equivalent up to: de-Bruijn-natural `Var` indices,
  source positions stripped, `MetaV` identities wildcarded, hidden
  bit preserved on `ArgInfo`, `ConInfo` / `ProjOrigin` /
  `DummyTermKind` (provenance) dropped. `QName` / `Sort` / `Level`
  / `Literal` go through `prettyShow` for stability — same
  convention as `hashQName`, so module-instantiation aliases
  collapse. Hashing via `Agda.Utils.Hash.hashString`.

  Single-pass bottom-up walk returns
  `(encoding, depth, [(hash, depth)])`. The encoding is reused at
  the parent level (no duplicate work); depth feeds the per-node
  emission gate. Cost is O(sum_subterms |encoding|), which is
  O(N) on balanced 'Term's and O(N²) maximally skewed — fine for
  Agda-proof scale (typically <1k nodes per def).

- **`--with-term-hashes`** — new flag (off by default). Walks
  `defType` + every `Function`/`Primitive` `clauseBody` per
  definition; populates new `ADDef._subtermHashes ::
  Maybe [Word64]` and `_subtermDepths :: Maybe [Int]` fields,
  both parallel.

- **`--min-term-depth=N`** — depth threshold for emission. Default
  `3`; `1` disables filtering. Empirically: on the reference corpus at `3`,
  hash volume drops ~3× (13.8M → 4.6M) and JSON file size drops
  43% (391 MB → 223 MB) versus the unfiltered launch.

- **Two new wire-format fields** in expanded JSON, both optional
  and additive at `schemaVersion: 2`:

    - `definitionSubtermHashes :: [[Word64]]` — parallel to
      `definitions`. Inner arrays hold one hash per emitted
      subterm.
    - `definitionSubtermDepths :: [[Int]]` — parallel to the above
      AND to `definitions`. Inner-array lengths must match between
      the two — enforced at decode time; mismatch is a clean
      decode error.

  Default-mode JSON (no `--with-term-hashes`) is byte-identical
  to round-5: both fields are absent rather than emitted as empty
  arrays.

---

## 2026-05-27 — `agda-deps` — YAML config (`.agda-deps.yml`)

The backend's CLI surface had grown large enough that every project
ended up wrapping the binary in a shell-script preamble that fixed
`--no-externals`, the view, and the colour palette. The wrapper scripts
are load-bearing config in disguise; this promotes them to a real file
format.

`agda-deps` now reads a YAML config from a project-local file (or an
explicit `--config=PATH`); CLI flags still win over the file, and
defaults still win over nothing. The schema mirrors the CLI surface
field-for-field, kebab-case = the flag name minus `--`.

### Schema and discovery

`AgdaDeps.Config` is the new module; `Options` and `commandLineFlags`
in `Backend.hs` were left untouched — the config layer composes on top
of the existing surface via `applyConfig :: A.Object -> Options ->
Either String Options`.

- Top-level keys are kebab-case mirrors of CLI flag names. Repeatable
  flags (`--exclude=PREFIX`, `--no-source-for=PREFIX`) accept YAML
  lists.
- Bad YAML types (e.g. `max-snippet-bytes: "lots"`) fail fast with a
  clean error naming file + key, exit 1.

Discovery (first match wins):

1. `--config=PATH` (new flag).
2. `$AGDA_DEPS_CONFIG`.
3. `./.agda-deps.yml` (or `.yaml`) in the current directory.
4. Walk up the directory tree from `cwd` to the first ancestor
   containing a `*.agda-lib` file; pick the dotfile there.

Merge order: **defaults → config → CLI**. A stderr breadcrumb
(`agda-deps: applied config from /abs/path/.agda-deps.yml`) fires
once when a config applies, unless `--quiet`.

Example `.agda-deps.yml`:

```yaml
format: html
view: module-dag-pods
theme: dark
no-externals: true
keep-going: true
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
```

Two CLI simplifications shipped alongside the config layer:

- **`--theme=default|light|dark|colorblind`.** Single-flag preset for
  the four state colours. `default` / `light` keep the round-4
  defaults (`#4caf50` / `#f44336` / `#9c27b0` / `#ff9800`); `dark`
  shifts to softened pastel hues (`#81c784` / `#ef5350` / `#ba68c8` /
  `#ffb74d`); `colorblind` swaps in the Cynthia Brewer
  `Dark2`-derived four-class palette
  (`#1b9e77` / `#d95f02` / `#7570b3` / `#e7298a`). Explicit
  `--color-*=#RRGGBB` flags still win over `--theme`. Configured in
  YAML as `theme: dark`.
- **Auto-format inference from `-o`.** When `--format` is **not**
  explicitly set and `-o` ends in `.html` / `.json` / `.dot`, the
  backend infers the format from the extension. `-o foo.html` is now
  equivalent to `--format=html -o foo.html`. Explicit `--format=…`
  always wins. Directory paths and extension-less filenames keep the
  default (`dot`).
- **Per-view shortcut flags deprecated.** The fourteen per-view
  shortcuts still work, but each emits a one-time stderr deprecation
  note on the first hit per process. Use `--view=NAME` (or
  `view: NAME` in `.agda-deps.yml`). TODO.md carries the removal entry.

Files: `src/AgdaDeps/Config.hs` (new), `src/AgdaDeps/Backend.hs`
(`--theme` / `--config` flag entries; auto-format inference;
view-shortcut deprecation breadcrumb), `agda-deps.cabal` (new
build-dep `yaml >= 0.11 && < 0.12`).

---

## 2026-05-27 — `agda-deps` — edge-provenance tagging

Expanded JSON now carries an optional `definitionEdgesProvenance`
array, parallel to `definitionEdges`, tagging each edge as one of
`signature | body | where | with | unknown`. `AgdaDeps.Deps` was
rewritten to:

- Walk `defType` and `theDef` **separately** (not the round-1
  `namesIn defType ++ namesIn theDef` concatenation).
- Tag each reference: names in `defType` are `Signature`; names in
  `theDef` are `Body`, refined to `With` when the parent's
  `funWith` points at the target (Agda 2.9 `IsWithFunction QName` —
  added `AgdaDeps.Util.isWithFun'` extracting the helper name) and
  `Where` when the qname's `prettyShow` contains the literal `._.`
  segment (Agda's anonymous-module marker for where-blocks; does
  not match user operators like `_+_` because those live as a
  single dotted segment).
- Combine via precedence `Signature > With > Where > Body >
  Unknown` (an edge appearing in both signature and body is
  `Signature`-tagged so it lands in the signature subgraph).

`ADDef` gained a strict `_depsProv :: !(Map QName EdgeProv)` field
with the invariant `M.keysSet _depsProv == _deps`. The side-channel
`IgnoredEdgeMap` was widened from `Map QName (Set QName)` to
`Map QName (Map QName EdgeProv)` so `contractIgnoredEdges` can
inherit provenance through hidden helpers — contracted edges
inherit the **source** side's tag toward the hidden chain (not the
chain's internal tags, which are discarded). `addInstanceMethodEdges`
adds inferred-method edges as `Unknown` via a left-biased `M.union`
so any pre-existing tag on the same key survives.

`Backend/GraphJson.hs` emits the new array in both modes:

- **Expanded mode**: `"definitionEdgesProvenance": ["signature",
  "body", ...]` — string array parallel to `definitionEdges`.
- **Packed mode**: an `Int8` array parallel to `outTargets`, with
  codes `0=signature, 1=body, 2=where, 3=with, 4=unknown`.
  Documented inline at `outTargetsProv`.

Schema stays at `v=2`. The field is additive and optional.

Smoke result on `test/Test.agda`: 185 edges total,
`{body: 113, signature: 62, unknown: 6, where: 4, with: 0}` (no
with-functions in the fixture, as expected). Two consecutive
`agda-deps` runs produce byte-identical output. All four CI
formats (`dot` / `html` / `html --lazy` / `json`) and the
`--no-externals` path are intact.

Files: `src/AgdaDeps/Util.hs` (new `isWithFun'`),
`src/AgdaDeps/Deps.hs` (the bulk of the change: `EdgeProv`,
`provPrec`, `tagOne`, `isWhereHelperName`, widened
`IgnoredEdgeMap`, threaded `_depsProv` through every rewrite site),
`src/AgdaDeps/Backend.hs` (`dropExternalDefs` filters `_depsProv`
in lockstep with `_deps`),
`src/AgdaDeps/Backend/GraphJson.hs` (`encodeEdgeProv`, `provJson`,
parallel arrays in both modes).

---

## 2026-05-27 — `agda-deps` — lazy-mode placeholder detail files for modules with no kept defs

The `--lazy` HTML output was declaring `moduleFiles[m]` entries for
every module in the project, including ones whose detail JSON files
were never written — externals like `Agda.Builtin.Nat` /
`Agda.Primitive` / `Agda.Primitive.Cubical`, and project modules
where every def got filtered by `ignoreDef` (the `DeadPrivate`
fixture). The HTML JS fetched the manifest path and 404'd silently.

Root cause: `buildGraphJson` populated `moduleFilesMap` for every
module in `modules`, but `buildModuleDetails` only emitted a detail
file for modules with at least one entry in `defsByModule`. The two
sets disagreed for the four cases above.

Fix: `buildModuleDetails` now also emits a stub detail JSON for
every module declared in `moduleFiles` but absent from
`defsByModule`. The stub carries the same shape as a real detail
file plus three discriminator fields:

```json
{
  "defs": {"names":[],"states":"","x":"","y":""},
  "outEdges": [],
  "placeholder": true,
  "reason": "external" | "filtered" | "failed",
  "module": "Agda.Builtin.Nat",
  "externalPostulates": ["true","false"]  // optional
}
```

Reason taxonomy: `external` (module in `egExternalModules`), `failed`
(module in `egFailedModules` under `--keep-going`), `filtered`
(everything else — the `DeadPrivate` case). When the upstream
`externals_summary` knows postulates for the external module, they're
attached as `externalPostulates`.

HTML side: eight view templates (`module-dag-pods` /
`big-module-dag-pods` / `ide-three-pane` / `notion-doc` /
`source-centric` / `wiki-backlinks` / `reading-order-narrative` plus
the legacy `deps.html.tmpl`) each gained two helpers
(`placeholderReasonText` + `renderPlaceholderHTML`) and a guard at
the fetch site so `if (detail.placeholder) { renderPlaceholderHTML
... }` short-circuits before the normal-defs-list rendering. Each
view styles the placeholder to match its own visual idiom
(pod-card / dark-IDE card / notion callout / source-comment block /
wiki stub banner / italicised narrative aside).

Wire-format additivity: schema stays at `v=2`. Older readers see
"extra fields" on the stub detail files and ignore them. Non-lazy
mode is unaffected (no `modules/` directory written, no
`placeholder` field appears in the inlined `var GRAPH = {…}`).
Expanded-mode `--format=json` is unaffected. Determinism preserved
across two consecutive `agda-deps --lazy` runs.

Files: `src/AgdaDeps/Backend/GraphJson.hs` (the `buildModuleDetails`
extension, +97/-9), `src/AgdaDeps/templates/deps.html.tmpl` plus
seven view templates under `src/AgdaDeps/templates/views/`.

---

## 2026-05-26 — `agda-deps` — `--no-externals` actually drops externals + `externals_summary`

### `--no-externals` actually drops externals

`agda-deps --format=json --json-mode=expanded --no-externals` was
still emitting hundreds of stdlib module names (`Agda.Builtin.*`,
`Agda.Primitive`, `Algebra.*`, `Data.*`, …) in the JSON's `modules`
array.

Root cause: `classifyExternalModules` derived its external set purely
from QNames with a resolvable source path via `srcLocOf`. Agda's
compiler-builtins carry `rangeFile = Nothing` on their binding sites
and were therefore never classified as external. Stdlib modules
visible only as import-edge endpoints (no surviving QName in the kept
graph) also escaped.

Fix: widened `classifyExternalModules` to take three signals — QNames,
`precomputedModuleFiles`, and all import-edge endpoint module names —
and treat a module as external when *no* signal places its source
under the project root (strict `Map String Bool` fold with `(||)`).
Re-ordered `postCompileAD` so `precomputed` and `visited` are read
before classification. Applied the `keep` predicate to `moduleFileMap`
so the `moduleFiles` field cannot leak an external/excluded path.
Centralised the filter in `keep` with a comment naming it as the
single source of truth for module-level wire-output filtering.

On `test/Test.agda`, `--no-externals` now reduces `modules` from 20 to
16 and `moduleEdges` no longer contains the 10 stdlib edges that were
previously leaking. Default (without `--no-externals`) is unchanged.
Verified across `--format=json --json-mode={expanded,packed}`,
`--format=html`, `--format=html --lazy`. Composition with `--exclude`
and `--keep-going` checked.

### `externals_summary` top-level field

A new top-level `externals_summary` field tags dropped externals so a
diagnostic record of the trusted base survives `--no-externals`. The
producer collects the summary BEFORE `dropExternalDefs` runs; the
field is omitted entirely when `--no-externals` is off (byte-identical
otherwise).

```json
"externals_summary": {
  "modules": ["Agda.Builtin.Bool", "Agda.Primitive", ...],
  "postulates_by_module": {
    "Agda.Builtin.Bool": ["true", "false"],
    "Agda.Builtin.Nat":  ["_+_", "_*_", "zero", ...],
    ...
  }
}
```

- New `ExternalsSummary` record in `AgdaDeps.Backend.GraphJson` (the
  schema's single source of truth) with hand-rolled JSON emission
  (consistent with the existing hand-rolled emitter).
- `buildExternalsSummary :: Set String -> [ADDef] -> ExternalsSummary`
  filters defs by `state == Postulate`, groups unqualified names by
  module, and feeds both packed and expanded JSON output paths.
- Threaded through `Backend.hs` (`postCompileAD`), `Backend/Json.hs`,
  `Backend/Html.hs` (HTML embeds the same JSON), `SkipAgda.hs`
  (initialised to `Nothing` — the skip-Agda path doesn't see
  postulates).

Files: `src/AgdaDeps/Backend.hs`,
`src/AgdaDeps/Backend/GraphJson.hs`,
`src/AgdaDeps/Backend/Html.hs`, `src/AgdaDeps/Backend/Json.hs`,
`src/AgdaDeps/SkipAgda.hs`.

---

## 2026-05-26 — `agda-deps` — per-definition `line`, `access`, instance reverse edges

- **`line` per definition.** Added `_line :: !(Maybe Int)` on
  `ADDef`; populated via a `bindingLine` helper around
  `nameBindingSite` → `rStart` → `posLine` from
  `Agda.Syntax.Position`. Emitted in expanded JSON as `"line": Int`
  (omitted when unknown). Packed JSON unchanged.
- **`access` per definition.** New `data DefAccess = AccPrivate |
  AccPublic` + `_access :: !(Maybe DefAccess)` on `ADDef`. Walking
  Agda's `iScope` turned out to be a dead end (Agda discards the
  per-decl `Access` tag after scope-checking, and the `PrivateNS`
  bags that survive carry imported non-re-exported names that would
  misclassify stdlib symbols). Switched to a source-level pre-scan
  (`findPrivateRanges` in `Backend.hs`) reading each `.agda` file
  once for top-level `private` blocks at column 0; `backfillAccess`
  in `postCompileAD` matches each def's `_line` against those ranges.
  Emitted as `"access": "private" | "public"`.
- **instance-declaration reverse edges.** New
  `methodProvidersRef :: IORef MethodProviderMap` side-channel in
  `Deps.hs` alongside the existing ignored-edges machinery.
  `recordInstanceMethods` runs from `compileDefAD`: records
  `defInstance`-marked binders plus any projection-method QNames
  pulled off head clause patterns (`ProjP`). `addInstanceMethodEdges`
  runs in `postCompileAD` right after `contractIgnoredEdges` — for
  every kept def, any dep that's a method key gets the providers
  appended to `_deps`. Purely additive; instance binders now have
  inbound traffic from anywhere their methods are dispatched.

Files: `src/AgdaDeps/Deps.hs`, `src/AgdaDeps/Backend.hs`,
`src/AgdaDeps/Backend/GraphJson.hs`.

Verified: `test/DeadPrivate.agda` produces the expected access split:
`reachable-priv` / `dead-priv` → `private`, `public-fn` /
`public-fn-deep` → `public`. Lines all match the source.

---

## 2026-05-25 — `agda-deps` — node-identity and dead-private recovery fixes

- **`ignoreDef` filters every `defCopy`** — module-instantiation copies
  for `Record` / `Datatype` / `Constructor` / `Projection` now ignored
  alongside `Function`. Previously surfaced as ghost "defined-here"
  entries under the importing module.
- **`hashQName` via `prettyShow`** — was hashing derived-`Show`, which
  included `NameId` metadata and could differ between QNames sourced
  from `iSignature` vs `stSignature`. Collapsed duplicate nodes.
- **Dead-end private definition recovery in `postModuleAD`** —
  Agda's `eliminateDeadCode` runs before serializing the interface, so
  unreachable top-level `private` defs were pruned from `iSignature`.
  We now diff `getSignature` (pre-prune) against visited QNames and
  feed missing defs through `compileDefAD`.

Commits: `6124d43`, `fdfb3fb`, `03cb077`, `01e48fc`, `436b1d7`.

---

## 2026-05-23 — Feature batch for re-exports / kind / edge contraction

### Edge contraction through ignored defs

Headline correctness fix. `using vqtc-b ← validBlockRQTC …` clauses
elaborated to `parent → with-NNN → ValidQTC.validBlockRQTC`; `ignoreDef`
was dropping the `with-NNN` and losing the edge.

Fix: `AgdaDeps.Deps.ignoredEdgesRef` records the raw out-edges of every
ignored def; `contractIgnoredEdges` (in `postCompileAD`) rewrites each
kept def's `_deps` by expanding hidden refs into their transitive
non-hidden targets. Side-effect: `ignoreDependency` filtering moved
from `computeDefAD` to `contractIgnoredEdges` so raw hidden refs
survive long enough to be expanded. Closure was `H × BFS` initially,
later switched to a topsort-based DP (Kahn) in `d00045a` — linear in
hidden-node count.

Effect on the reference corpus: edges 114,963 → 228,192 (+98%).

Files: `src/AgdaDeps/Deps.hs`, `src/AgdaDeps/Backend.hs`.
Commits: `4492c08`, `469bc9b`, `d00045a`.

### `kind` discriminator on definitions

Each `ADDef` carries `_kind :: !DefKind` derived structurally from
`theDef`: `function` / `projection` / `datatype` / `record` /
`constructor` / `postulate` / `primitive` / `other`. Emitted in
expanded JSON; lets consumers filter without string-scraping qnames.
Note: Agda 2.9's `funProjection` is `Either ProjectionLikenessMissing
Projection`; projection matches `Right{projProper = Just _}`.

Commit: `3a573fa`, `6dbd85f`.

### `reexports[]` in expanded JSON

Captures `open import M public` and parameterised
`module N (… : R) where open R public …` re-exports. Producer walks
each visited `Interface`'s `iScope` over both
`NameSpaceId.ImportedNS` *and* `PublicNS` namespaces — both needed
(`ImportedNS` for plain `open … public`, `PublicNS` for re-exports
through parameterised module applications).

Note: `iScope` is reconstructed from `iInsideScope` at deserialise
time via `publicModules` (`Agda.Interaction.Imports.constructIScope`),
so the data is available even from cached `.agdai`.

Commits: `ec51c27`, `5eb876e`.

---

## 2026-05-22 — G12 · external feature-request batch (`157c332`)

Shipped 9 of 14 items from an external feature-request batch.
Items not built are documented in [Backlog.md](Backlog.md).

- `--version` / `-V` / `--numeric-version` — early intercept in `Main`;
  reports the backend's version, not Agda's.
- `--quiet` — silences progress chatter via `AgdaDeps.Logging.info`
  backed by a global `quietRef` IORef.
- `--no-externals` — drops external modules from the rendered graph
  entirely (`dropExternalDefs` in `Backend.hs` for the Agda path,
  separate filter in `SkipAgda`).
- `--json-mode=packed|expanded` — selects `--format=json` shape.
  Expanded ships `definitions` as `[{id, name, module, state, x?, y?}]`
  + qname / module-name string edge pairs + explicit `schemaVersion`
  and `mode` at the top level.
- `--lenient-imports` — rewritten in `Main.hs` to `--allow-unsolved-metas`
  before argv reaches Agda. Useful with `--keep-going` on projects whose
  commits deliberately contain `?` holes.
- `-o` directory auto-created via `createDirectoryIfMissing True`.
- `Options` grew `JsonMode = JsonPacked | JsonExpanded`, plus
  `optQuiet`, `optNoExternals`, `optJsonMode`, `optLenientImports`.

Docs:
- `CLAUDE.md` gained the "State semantics" (D / P / H / F) and
  "v2 graph.json schema" sections.

---

## G11 — `--skip-agda` (`b952db9`)

Short-circuits the entire Agda pipeline. `Main.hs` detects `--skip-agda`
and routes to `AgdaDeps.SkipAgda.runSkipAgda`. The renderer consumes
the data `AgdaDeps.Precompute` was already producing (line-parsed
`module …` / `import …` declarations across all `.agda` sources under
the `-i` paths).

- Backend options parsed via `getOpt' Permute` + `runOptM` over argv.
- `Precompute.parseHeader` falls back to `takeBaseName path` for files
  declaring `module _ where`, matching Agda's surface behaviour.
- `GraphInput` got `giExtraModules :: Set String` so orphan
  precomputed modules (no imports, not imported by anyone) appear.
- `renderHtmlFromInput` exposed in `Backend.Html` so `SkipAgda` can
  hand it a fully-built `GraphInput`.
- External classification: modules whose source lives outside `cwd`,
  plus modules that appear only as import targets.

Trade-off: no def graph, no D/P/H classification, no source snippets.
Module-DAG views render normally; def-level views show empty pods.
Runs in milliseconds regardless of project size.

---

## G10 — Scaling to ~1M defs / 100k modules (`f6606c3`)

Audited the Haskell pipeline for O(n²) hot spots; switched to strict
`Map` / `IntMap` / `IntSet` / `Set` folds throughout. Byte-identical
output for the test corpus.

- `Layout.moduleGrouped` — `IntMap` with cons-accumulation (was
  `M.fromListWith` with list `(++)`, O(k²) per module).
- `GraphJson.bfsFrom` / `bfsDepths` — stack-style / `Data.Sequence`
  instead of list queues.
- Six `nub` call-sites collapsed to Set-based dedup.
- `moduleEdgePairs` — folds directly into `Set (Int, Int)`.
- `Deps.collectAllQNames` — folds into `IntMap QName`.
- `Csr.buildCsr` — fused per-source `length` + `concatMap` into a
  single strict sweep.
- `Backend.computeQNamePositions` — `IntSet` / `IntMap`; cheap
  membership test first in the edge filter.
- `moduleStateCounts` — strict `data Counts !Int !Int !Int !Int`.
- `buildSearchIndex` bigrams — gated above 50k combined names; JS
  falls back to linear scan.

---

## G9 — Multi-view HTML system

Replaced the single cytoscape template with a `View` ADT and one
template per "concept" view under `src/AgdaDeps/templates/views/`:

- `module-dag-pods` *(default)* — top-down DAG of expandable module
  pods via dagre.
- `cytoscape` — original compound-node viewer.
- `ide-three-pane`, `source-centric`, `notion-doc`, `wiki-backlinks`
  — definition-level concept views.
- `sigma` — WebGL via sigma.js + graphology + dagre; falls back to
  concentric above 3000 modules.
- `big-module-dag-pods` — viewport-virtualised port for ~100k modules.
  Pre-computes dagre layout Haskell-side via `buildModuleDagLayout`
  (Kahn + column-pack, O(V+E)); packed into v2 schema as
  `modulePodLayout`; JS uses a spatial-grid for O(visible) viewport
  queries + a minimap canvas for navigation.
- `progress-dashboard`, `critical-path-holes` — KPI / kanban dashboards.
- `sunburst-hierarchy`, `cartographic-atlas`, `reading-order-narrative`,
  `pixel-grid-overview` — hierarchical / textbook / heatmap views.

Selection: `--view=VIEW` + per-view shortcut. All views consume the
same v2 `graph.json` payload.

---

## G8 — Custom `--help` (`AgdaDeps.Help`)

Agda's own `--help` lists hundreds of flags. `Main.hs` intercepts plain
`--help` / `-h` / `-?` before `runAgdaArgs` and routes to
`printHelp`, which uses `Agda.Utils.GetOpt.usageInfo` over only the
backend's `commandLineFlags`. Topic forms (`--help=warning`, etc.)
still forward to Agda. New `--agda-help` is rewritten to plain
`--help` for users who want Agda's upstream printer.

---

## G7 — Partial compilation under `--keep-going`

Standard `Agda.Main.runAgda` aborts on the first `TCErr`, so
`postCompile` never fires. Forked into `AgdaDeps.ModuleExplorer`:

- `partialBackendInteraction` catches `TCErr` from `check mainFile`,
  records the failing module via a caller-supplied
  `reportFailed :: String -> IO ()` callback, and drives each backend
  manually over the modules Agda did load.
- `partialCompilerMain` re-seeds `stVisitedModules` from the
  persistent `stDecodedModules` (imports drop the per-`freshTCM`
  `stVisitedModules` on failure), runs `preCompile`, then
  `postCompile` with an empty `defs` map.
- `AgdaDeps.Driver` is a thin shim wiring `failedModulesRef` to the
  callback.

---

## G6 — Auto-discover `.agda-lib` for non-cwd invocations (`64f3955`)

Plain `agda` only looks for `.agda-lib` in cwd. Invocations from
outside the project failed (library deps like `standard-library`
never consulted).

Pre-process argv before `runAgdaArgs`: walk up from each `-i` /
`--include-path` and each `.agda` / `.lagda*` positional looking for
an ancestor containing a `*.agda-lib`. Canonicalize path-bearing
argv entries to absolute paths *first* so a relative `-o foo/` still
resolves against the user's original cwd. `setCurrentDirectory` to
the discovered root. Skip the dance when `--no-libraries`, `--library`
/ `-l`, or `--library-file` is already passed.

Verified on the reference corpus: ~21k nodes, ~17k embedded snippets.

---

## G5 — Bump to Agda 2.9 (`7f50db8`)

- `cabal.project` pins Agda as `source-repository-package` from
  `github.com/agda/agda` (2.9.0 isn't on Hackage yet).
- `agda-deps.cabal`: `Agda >= 2.9 && < 3`.
- `graphviz >= 2999.20` to dodge older versions' `<>` ambiguity in
  `Data.GraphViz.Types.Printing` on GHC ≥ 9.
- Adapted to `_funWith :: Maybe QName` → `IsWithFunction QName` via
  the `isWithFun` helper.

---

## G4 — Linked source view (`edda6a5`, `76fbe68`)

`--with-source` embeds each definition's source code in a slide-in
drawer, rendered with Agda's native semantic highlighting.

Implementation drives Agda's `defaultPageGen` programmatically from
`postCompileAD`:

1. Per-module Agda HTML to a temp dir under `-o`.
2. Extract `<pre class="Agda">` block from each file
   (`extractPreBlock`).
3. For each leaf QName: find binding line via `srcLocOf`, compute
   `paragraphBounds` against the cached `.agda` source, slice the
   highlighted HTML by line (`sliceHtmlByLine`).
4. Inline `source` + `sourceLine` on each node's JSON.
5. Remove temp dir.

Line slicing is safe because Agda's rendered `<pre>` keeps newlines
as plain text *outside* any `<a>` tag.

---

## G3 — Node colouring by state (`0283d32`)

Definitions classified as `Defined` / `Postulate` / `Hole`, tagged on
`ADDef`. Palette via `--color-defined` / `--color-postulate` /
`--color-hole` (defaults `#4caf50` / `#f44336` / `#9c27b0`). Both DOT
(`FillColor` + `Style Filled`) and HTML honour the same palette.

Hole detection has three signals because Agda's
`openMetasToPostulates` rewrites `?` into synthetic
`unsolved#meta.*` postulates before backends fire: syntactic `MetaV`
walk over `defType`/`theDef`, the def's name itself, and references
to synthetic-meta names.

---

## G2 — HTML interactive backend (`0283d32`)

Added `--format=dot|html` and a self-contained browser-explorable HTML
output backed by [cytoscape.js](https://js.cytoscape.org/). Modules as
collapsible compound parent nodes (`cytoscape-expand-collapse`).
Cytoscape loaded from CDN; graph inlined as JSON. Output routed via
`-o/--out-dir`.

---

## G1 — Remove nix scaffolding (`0283d32`)

Stripped `flake.nix` / `flake.lock`. Project builds purely via
`cabal`.
