# Changelog

History of notable changes to `agda-deps`. Reverse-chronological. For
runnable recipes see [Examples.md](Examples.md); for forward-looking
work see [TODO.md](TODO.md); for deferred / refused ideas see
[Backlog.md](Backlog.md).

---

## 2026-07-10 — `agda-deps` — tag file-level `{-# OPTIONS #-}` soundness escapes (R15)

Soundness-escape Phase 2, completing the Phase 1 per-def `unsafe` work
(2026-07-09). Phase 1 covered per-def escapes (`NON_TERMINATING`,
`primTrustMe`), but a *whole-module* escape via a file pragma
(`{-# OPTIONS --type-in-type #-}`, `--no-positivity-check`, `--rewriting`,
…) left every def in the module as plain `state: "D"`, so a graph-derived
`agda --safe` audit still missed it.

- **New optional top-level `moduleOptionEscapes`** — a `Map module
  [String]` (object keyed by module name; values the offending flag
  tokens). Read from each visited interface's **`iFilePragmaOptions`** —
  the file's own `OPTIONS` tokens — in `postCompileAD`, keeping only the
  safety-relevant flags (`AgdaDeps.Deps.safetyRelevantOptionFlags`, the
  unconditional single-flag set of Agda's own `unsafePragmaOptions`).
- **File-level, not resolved.** Deliberately `iFilePragmaOptions` and NOT
  `iOptionsUsed` (the fully-resolved per-module options): `iOptionsUsed`
  folds in command-line + library-default options, so it would
  misattribute e.g. `--lenient-imports` (⇒ `--allow-unsolved-metas`) or a
  library `.agda-lib` default to *every* module. The file scan is
  pollution-immune and exactly "what this file declared".
- **Boundary (verified, documented).** A per-block `{-# NO_POSITIVITY_CHECK #-}`
  is a *declaration* pragma, not an `OPTIONS` pragma, so it never appears in
  `iFilePragmaOptions` and is not captured; nor are combination-conditional
  escapes (`--without-K` + `--flat-split`, …). Pinned by
  `test/OptionEscapes.agda`, whose file-level `--type-in-type` surfaces
  while its block `NO_POSITIVITY_CHECK` does not.
- Emitted in expanded + packed + lazy `graph.json`, module-level (orthogonal
  to per-def `unsafe`), omitted when empty so escape-free corpora stay
  byte-identical. Additive wire field: `schemaVersion` stays 2,
  `nodeKeyVersion` stays 3. Schema oracle updated from `Wire.hs`; golden
  regenerated cold (`Holes`/`Test` carry their real `--allow-unsolved-metas`,
  `OptionEscapes` its `--type-in-type`). No `--incremental` fragment bump:
  escapes are recomputed from the visited interfaces every run, not cached.
- Both Agda 2.8 and 2.9 builds compile unchanged — `iFilePragmaOptions` /
  `OptionsPragma` are identical across the range, so no CPP.

## 2026-07-09 — `agda-deps` — tag soundness escapes beyond postulates (`unsafe`)

Acting on external feedback: the graph flags postulates (`state: "P"`) and
unsolved holes (`"H"`), but a `{-# NON_TERMINATING #-}` function or a body
built on `primTrustMe` emitted as plain `state: "D"` — indistinguishable
from safe code, so a graph-derived `agda --safe`-style audit missed them.

- **New optional per-def `unsafe` array** — the escapes a definition uses
  **directly** (not transitively): `non-terminating` (a
  `{-# NON_TERMINATING #-}` function, `funTerminates = Just False`) and
  `trustme` (the body/type references `primTrustMe`). Orthogonal to
  `state`: a def can be `D` and still carry an escape. Always computed (no
  flag; the signals are already in hand during the per-def walk), omitted
  when empty, so escape-free corpora produce byte-identical output.
- **Packed-analytical parity:** a dense `unsafe` `Int8` bitmask array
  (bit 0 = `non-terminating`, bit 1 = `trustme`; `0` = none), so a decoded
  packed graph stays node-for-node identical to expanded
  (`schema/packed_analytical_check.py` extended to decode + compare it).
- **`{-# TERMINATING #-}` was deliberately dropped.** Verified against the
  corpus that Agda's ordinary termination checker also writes
  `funTerminates = Just True` for every proven-terminating def, so the
  marker can't be told apart from a normal proof — it would fire on
  `Nat._+_`, `Test.sum`, and friends. `non-terminating` alone fixes the
  measured audit miss.
- Additive wire field: `schemaVersion` stays 2, `nodeKeyVersion` stays 3.
  Schema oracle regenerated from `Wire.hs`; golden regenerated cold.
  `--incremental` fragment format bumped 2 → 3 (tags ride the fragment, so
  a `Skip`ped module keeps them; older caches self-invalidate).
- Fixture: `test/Unsafe.agda` (`NON_TERMINATING`, `primTrustMe`, a
  `TERMINATING` control, and a plain function that must carry no tag).

## 2026-07-09 — `agda-deps` — emit `renaming` aliases on public re-exports

Acting on external feedback: `open import M public renaming (merge to
combine)` re-exports `M.merge` under the in-scope name `combine`, but the
expanded `graph.json` `reexports[]` rows carried canonical FQNs only, so a
consumer could not resolve `combine` back to `M.merge`. The alias was
already computed in `collectReExports` and discarded.

- **New optional `renames` map** on each expanded-mode `reexport` object:
  `{ alias-in-scope-name: canonical-nodeKey }`, where the canonical value
  is a member of that row's `names`. Omitted when the row has no renamed
  entries, so rename-free corpora produce byte-identical output.
- Expanded-only — packed and `--lazy` never emitted `reexports`, so there
  is no packed-analytical or lazy work, and no fragment-format bump
  (re-exports are derived in `postCompile`, not cached).
- Additive wire field: `schemaVersion` stays 2, `nodeKeyVersion` stays 3.
  Schema oracle regenerated from `Wire.hs`; golden regenerated cold.
- Fixture: `test/RenamedReexport.agda`
  (`open import Nat public renaming (Nat to Number)`).

## 2026-06-30 — `agda-deps` — fix: `wiki-backlinks` view back/forward navigation

The `wiki-backlinks` view named its navigation stack `history`, which
at global script scope aliases the read-only `window.history` — so the
first `navigate(…, push)` threw `history.slice is not a function` and
broke back/forward. Renamed the stack to `navHistory`. HTML-only.

## 2026-06-30 — `agda-deps` — lift anonymous-module definitions into their parent (nodeKeyVersion 3)

Fixes the anonymous-module blind spot: defs inside `where` blocks and
`module _ (…) where` sections produced false module-level and provenance
results. Agda desugars both into anonymous sub-modules (`Mod._`) and
lifts enclosing variables into each def's `defType`, so the dependency
edges were already correct — only naming/attribution/provenance was wrong.

- **`nodeKey` lifts anonymous segments** (`liftAnonSegments`):
  `Mod._.helper@15` ↦ `Mod.helper@15`, `Mod._._.deep` ↦ `Mod.deep`.
  The `@<line>` disambiguator is preserved; mixfix names (`_+_`) are
  untouched. `nodeKeyVersion` bumped 2 → 3.
- **`moduleKey`** re-homes module attribution to the nearest *named*
  ancestor; every QName→module-string site routes through it, killing
  phantom `Mod._` nodes and their false `Mod ⇄ Mod._` cycles.
- **Provenance `where` → `module-local`**: the tag describes the target
  (an anonymous-module-local helper) rather than claiming an
  unrecoverable source-ownership relation. Packed int encoding unchanged
  (still `2`); expanded string + schema enum updated.

`where` and section are represented identically post-scope-check, so
they are not distinguished. Cold golden regenerated. New regression
`test/AnonSection.agda`; `test/Collision.agda` still locks the `where` case.

## 2026-06-18 — `agda-deps` — rebuild-memory reductions

Memory pass on the producer's rebuild path. The dominant peak-RSS term
is Agda's own interface-load floor (irreducible in a whole-program
backend); of the removable remainder, copying-GC slack was the largest.
Output is byte-identical.

- **`-rtsopts -with-rtsopts=-F1.2`** (`agda-deps.cabal`). The binary had
  no `-rtsopts`, so `+RTS`/`GHCRTS` were ignored. `-F1.2` caps old-gen
  heap growth at 1.2× live (default 2.0×): ~11% lower peak RSS at no
  measurable wall cost, no hard ceiling. `-rtsopts` lets callers override.
- **Strict `_deps`/`_state` in `ADDef`** — the two fields that lacked
  `!`; a lazy `_state` thunk closed over the whole Agda `Definition`.
- **Force `liveModules`** (`Backend.hs`) — a lazy `[String]` pinned the
  entire `defMap` alive through the render in non-`--incremental` runs.

`--incremental` is a wall-time win, not a memory one.

## 2026-06-13 — `agda-deps` — `--packed-analytical` (consumer-usable packed form)

Packed `graph.json` is ~5× smaller than expanded but omitted every
per-definition analytical field. `--packed-analytical` adds them so
consumers no longer have to choose size or fidelity.

- **New arrays parallel to `defs.names`**: `defs.kinds` (Int8),
  `defs.lines` (Int32, `-1`=unknown), `defs.access` (Int8),
  `defs.types` (under `--with-signatures`), CSR-packed subterm
  offsets/hashes/depths (under `--with-term-hashes`). No topology change.
- **`access` is 3-valued** (`0`=unknown/absent, `1`=public,
  `2`=private): expanded *omits* `access` for QNames with no local
  `ADDef`, and `0` round-trips to that omission (`line`→`-1`, `type`→null
  likewise), so the two forms match exactly.
- **Shared per-QName lookups** guarantee parity between the expanded
  emitter and the packed arrays — don't inline them back per-form.
- Off by default; default packed output stays byte-identical. Only
  meaningful with `--json-mode=packed`. Gated by
  `schema/packed_analytical_check.py` (run both sides cold).

## 2026-06-13 — `agda-deps` — incremental serialise (P2), cache GC + `--cache-dir`, re-export-hub externals

### Incremental serialise (P2)

New `AgdaDeps.SerialiseCache` (plain-text manifest; no CPP) cuts
serialise+write on a rebuild, on top of P1's per-definition walk cut.

- **Monolithic output** (`deps.json`/inline `deps.html`) can't be
  patched cheaply, so the win is the no-op rebuild: when nothing
  recompiled (`recompiledRef`) *and* the `outputToken` (module set +
  output-affecting options + build identity + `nodeKeyVersion`) matches,
  generation and write are both skipped. Both guards are required —
  the token alone misses a recompiled body, `recompiledRef` alone misses
  a toggled rendering option.
- **Lazy per-module files** carry a content epoch computed from the
  structured inputs (no base64), so a skipped file never forces its
  content thunk. Adding/removing a def shifts global indices, so many
  epochs change (correct if not minimal).
- Profiling shows the warm-rebuild floor is Agda's interface load, which
  a backend cannot avoid; this helps signature-/source-heavy output and
  no-op rebuilds, not the floor.
- Gated on `--incremental`; default output path byte-identical.

### Fragment cache GC + `--cache-dir`

- **GC**: after an `--incremental` run, `*.frag` files for modules no
  longer in the graph are pruned (`gcFragments`); only `*.frag` touched.
- **`--cache-dir=PATH`** (CLI + YAML) overrides the default
  `<out-dir>/.agda-deps-cache` for fragments and the serialise manifest.

### `classifyExternalModules` sees re-export hubs

A stdlib module that only `open … public`s names contributes no QName of
its own and slipped past `--no-externals`. The re-export host + source
module names (`collectReExports`) are now pooled into the classification
input. Additive: golden unchanged.

## 2026-06-12 — `agda-deps` — `--keep-going` hardening: a graph is always emitted

On a real broken corpus the partial pass died with a bare exit 120 and
no `deps.json`. Root cause: exit 120 is Agda's `__IMPOSSIBLE__`, a GHC
exception (not a `TCErr`), invisible to every `catchError` guard; and
TCM's `catchError` rolls back `TCState`, so re-merging only interface
*signatures* left reification hitting a missing-builtin `__IMPOSSIBLE__`.

- **`mergeIfaceState`** now rebuilds the import state as Agda's own
  `mergeInterface` does: signature + builtins (with per-primitive
  rebinds) + remote metas + pattern synonyms + display forms.
- **`catchAllTCM`** (catches TCErr *and* GHC exceptions; re-throws
  `ExitCode`/async) guards every stage — per definition, per module, per
  interface merge; `preCompile`/`postCompile` failures print a
  stage-named diagnostic before re-throwing.
- **The partial pass no longer claims an entry module** — it passed
  `IsMain` to every module, so `entryModule` recorded whichever ran last.
- Fixture + CI step `test-keepgoing/` (kept outside `test/`): entry
  imports one healthy and one failing module; CI asserts `deps.json` is
  produced with `failedModules == ["Broken"]`.

## 2026-06-12 — `agda-deps` — `--incremental`: per-module fragment cache

P1 of the incremental-rebuild design: the dominant rebuild cost is the
per-definition backend walk, re-run for every module even when nothing
changed. `AgdaDeps.FragmentCache` caches, per module, what `postModuleAD`
returns plus the module's contributions to the two compile-time
side-channels (ignored edges, instance-method providers).

- **The slices are exact before/after deltas** snapshotted in
  `ModuleEnv` — a `Skip`ped module never runs `compileDef`, so without
  them contraction silently loses edges through its helpers. A
  name-prefix filter is wrong: it misses defs Agda homes in anonymous
  modules at prefixless QNames.
- **Key**: `(fragment format version, content-option fingerprint,
  iFullHash, nodeKeyVersion)`. `iFullHash` folds in transitive imported
  hashes, invalidating exactly the affected cone; rendering-only options
  are excluded.
- **Flow**: `moduleSetup` returns `Skip` on a hit. `postModuleAD` writes
  imported modules unconditionally, the **main module only from a fresh
  check** (its output is enriched by the `getSignature` dead-private
  recovery a warm load can't see), so a fragment hit serves the complete
  main-module variant even warm.
- **Serialisation** via Agda's `EmbPrj`, so `QName`s (NameIds, ranges)
  round-trip exactly. The byte layer is only exposed by Agda ≥ 2.9; on
  2.8 the flag warns + no-ops.
- `--incremental` / YAML `incremental: true`; disabled under
  `--keep-going`. All failure modes degrade to recompute, never abort.
  CI: cold-write + warm-hit must be byte-identical and match the golden.

## 2026-06-12 — `agda-deps` — golden snapshot regenerated from a cold run

The committed golden had been generated warm, freezing the degraded
main-module variant (missing `Test.Int-0`-class pattern-helper
edges/kinds/types — the "warm-`.agdai` edge loss"). The golden is now the
cold (complete) variant, and CI clears `.agdai` before the runs that feed
the golden check. The warm loss is main-module-only: imported modules'
emission is a pure function of their pruned interface.

## 2026-06-12 — `agda-deps` — expanded-graph invariants + golden snapshot (phase 3)

- **`toExpandedGraph`** extracted from `buildExpandedJson` (now a thin
  validate-then-encode wrapper).
- **`Wire.validateExpanded`** asserts the structural invariants JSON
  Schema can't express (provenance/subterm array lengths, edge endpoints
  name a definition); `buildExpandedJson` `error`s on a violation.
- **Golden snapshot guard**: `test/golden/expanded.golden.json` +
  `schema/golden_check.py` catch content regressions; the normaliser
  strips build/layout/path-volatile fields so it's portable. New CI step.
- Output byte-identical (refactor + new guards).

## 2026-06-12 — `agda-deps` — expanded emission routed through the schema source of truth (phase 2)

The expanded `graph.json` is now encoded from the same
`AgdaDeps.Backend.Wire` field tables that generate the schema, closing
the drift gap by construction.

- **`buildExpandedJson` builds an `ExpandedGraph` and calls
  `encodeExpanded`** (= `encodeObject expandedFields`). Each field-table
  row carries wire name, schema fragment, and byte encoder together, so a
  field can't be emitted without appearing in the generated schema. The
  old hand-rolled per-field assembly is gone.
- **`Wire` now owns the expanded wire tags** (`wireState`/`wireKind`/
  `wireAccess`); the duplicates in `GraphJson` were removed.
- Output byte-identical; `packed`/`--lazy` untouched (still in `GraphJson`).

## 2026-06-12 — `agda-deps` — expanded-schema single source of truth + drift check (phase 1)

Closes the silent-schema-drift gap: open `additionalProperties` let a new
producer field slip past validation undocumented.

- **`AgdaDeps.Backend.Wire`** describes the v2 expanded wire shape once
  (field tables + a small `SchemaDoc` ADT).
- **`agda-deps --emit-schema`** prints the JSON Schema generated from it.
- **`schema/check_schema.py`** + a CI step diff the generated schema
  against the committed oracle *structurally*; the committed file is
  never overwritten, so a wire-shape change must update it deliberately
  or the check fails.
- Schema-only: no new runtime fields, no reroute; output byte-identical.

## 2026-06-12 — `agda-deps` — `--version` reports the build fingerprint; install recipe

- **`--version` / `-V`** now print the full build fingerprint (version +
  git rev + build date + GHC), the same string stamped into `graph.json`
  as `"producer"`; previously only the bare semver. `--numeric-version`
  stays bare for tooling.
- **Documented `cabal install exe:agda-deps --overwrite-policy=always`**
  so callers get a stable on-`PATH` binary.
- **`AGDA_DEPS_GIT_REV` override** for `BuildInfoTH`: `cabal install`
  builds from an sdist with no `.git`, so the git splice otherwise
  reports `git unknown`; the env var lets an installer stamp the commit.
  In-tree builds are unaffected (git wins when present).

## 2026-06-05 — `agda-deps` — build provenance stamped into `graph.json`

- **Build fingerprint baked into every binary (`BuildInfo`)** — package
  version, git revision (`+` for a dirty tree), compile date, compiling
  GHC (TH for git, CPP for the date). Reported by `--version`.
- **Graph provenance in `graph.json`** — both emitters write `"producer"`
  and `"nodeKeyVersion"`. Additive/optional; older JSON parses with
  `nodeKeyVersion` defaulting to `1`.

## 2026-06-05 — `agda-deps` — same-named helpers no longer collapse (E1 node collision)

Node identity now keys on `nodeKey`: `prettyShow` for top-level names
plus a `@<binding-line>` suffix for `._.`-marked helpers, which
`prettyShow` otherwise renders identically across every same-named helper
in a module (so the last won and the rest's edges vanished). The
binding-site line is the one per-helper coordinate stable across
signature sources (`NameId` is not — hence the long-standing `hashQName
= prettyShow` invariant). `hashQName`, the wire `name`, and edge
endpoints all derive from `nodeKey`; the expanded-edge filter resolves
by canonical string, not `QName` `Ord`. Top-level keys byte-identical.
Regression in `test/Collision.agda`.

## 2026-06-05 — `agda-deps` — opt-in normalised / implicit signatures

**`--normalise-signatures`** reduces each type to semantic form before
reifying; **`--signature-implicits`** shows implicit/irrelevant args
(named to avoid clashing with Agda's `--show-implicit`). Both default
off, so default `--with-signatures` output is byte-identical.

## 2026-06-04 — `agda-deps` — rendered type signatures (`--with-signatures`)

Renders each definition's type — `prettyTCM` of `defType`, not
normalised, default printing, one line — as the optional per-def `"type"`
field in expanded JSON. Additive: absent without the flag, so default
output is byte-identical. Mirrored in YAML as `with-signatures`.

---

## 2026-06-01 — `agda-deps` — `--agda-html-dir` + sunburst "Open source"

New flag `--agda-html-dir=DIR` links the HTML views to the pages
`agda --html` already wrote, instead of embedding snippets with
`--with-source`. Emitted into every view's data-loading prelude as the
`AGDA_HTML_BASE` JS var (trailing-slashed, or `null` when absent),
interpreted relative to the generated HTML file. Plumbed like every other
flag (`Options` + parser + `commandLineFlags` + YAML `agda-html-dir` +
`NFData`).

First consumer: the **`sunburst-hierarchy`** view. When `AGDA_HTML_BASE`
is set, module arcs and the centre disc gain an **Open source ↗**
affordance (module link needs no char-offset anchor — the filename is
`<Module.Name>.html`); external/builtin modules are suppressed.
Everything gated on `AGDA_HTML_BASE`, so output is unchanged when the
flag is absent.

---

## 2026-05-29 — `agda-deps` — `--lenient-imports` docs, `--resolve-deps`, partial `--keep-going` emission

### `--lenient-imports` × `--safe` incompatibility documented

`--lenient-imports` is an argv rewrite to `--allow-unsolved-metas`; any
`--safe` module in the dep closure (including stdlib) rejects it with
`[SafeFlagPragma]`. Documented in `--help` and README, recommending
`--keep-going` alone for safe-stdlib projects.

### `--resolve-deps` flag

Opt-in resolution of the project's `.agda-lib` `depend:` closure into an
explicit `--no-libraries -i <dir> …` argv expansion. Use case: when
multiple versions of the same library are registered, Agda's resolver
picks ambiguously (`[AmbiguousTopLevelModuleName]`). New module
`AgdaDeps.LibResolve` reads `~/.agda/libraries`, walks the transitive
closure, and pins the include dirs. Wired through `Main.hs`; YAML
`resolve-deps: true`. Falls back silently (with a breadcrumb) if there's
no `.agda-lib` or a dependency can't be resolved.

### Partial def-level emission under `--keep-going`

Previously, when a downstream module fatally failed, all def-level data
from successfully-loaded modules was discarded — the graph collapsed to
module-level only. Two fixes:

1. **`catchError` now also wraps `setup`**, not just `check mainFile`,
   so a `TCErr` before checking starts (e.g. `OptionError`,
   `SafeFlagPragma`, library-resolution ambiguity) is reported, not
   escaped.
2. **The failure branch re-drives `preModule → compileDef → postModule`
   per decoded module**, accumulating results for `postCompile`; each
   module's hooks are wrapped so one broken module is skipped.

Load-bearing: before the loop, every decoded interface's `iSignature` is
merged into `stImports` and `stSignature` cleared — without this,
downstream `getConstInfo` in `contractIgnoredEdges` fails with `Unbound
name` panics on cross-module dep edges. Normal mode is byte-identical.

---

## 2026-05-29 — `agda-deps` — remove the 14 view-shortcut boolean flags

Drop the deprecated per-view shortcut flags (`--cytoscape`, `--sigma`,
`--module-dag-pods`, `--ide-three-pane`, `--source-centric`,
`--notion-doc`, `--wiki-backlinks`, `--big-module-dag-pods`,
`--critical-path-holes`, `--progress-dashboard`, `--cartographic-atlas`,
`--sunburst-hierarchy`, `--reading-order-narrative`,
`--pixel-grid-overview`). Deprecated 2026-05-27; passing one now errors
as an unrecognised option. The replacement remains `--view=NAME` (or
`view: NAME` in YAML). Removal drops `setViewShortcutOpt` and the
`optSawViewShortcut` field; the `View` ADT, `viewSlug`, and `viewOpt`
parser stay.

---

## 2026-05-28 — `agda-deps` — round-6 P3 (AST subterm fingerprinting)

Cross-file CSE / lemma-extraction candidate detection over canonicalised
internal `Term`s.

- **`AgdaDeps.TermCanon`** — canonical-form byte encoder for
  `Agda.Syntax.Internal.Term`. Two terms hash equal iff alpha-equivalent
  up to: de-Bruijn `Var` indices, positions stripped, `MetaV` wildcarded,
  hidden bit preserved, provenance (`ConInfo`/`ProjOrigin`/…) dropped;
  `QName`/`Sort`/`Level`/`Literal` via `prettyShow` (same convention as
  `hashQName`, so module aliases collapse). Single bottom-up walk returns
  `(encoding, depth, [(hash, depth)])`, reusing the encoding at the parent.
- **`--with-term-hashes`** (off by default) — walks `defType` + every
  clause body; populates parallel `_subtermHashes :: Maybe [Word64]` and
  `_subtermDepths :: Maybe [Int]`.
- **`--min-term-depth=N`** — emission threshold, default `3` (`1`
  disables filtering); cuts hash volume substantially.
- **Two optional wire fields** in expanded JSON at `schemaVersion: 2`:
  `definitionSubtermHashes` and `definitionSubtermDepths`, both parallel
  to `definitions`; inner-array lengths must match (enforced at decode).
  Default-mode JSON is byte-identical (both fields absent, not empty).

---

## 2026-05-27 — `agda-deps` — YAML config (`.agda-deps.yml`)

`agda-deps` now reads a YAML config from a project-local file (or
explicit `--config=PATH`), promoting the shell-wrapper preambles projects
used into a real format. New module `AgdaDeps.Config` composes on top of
the existing surface via `applyConfig :: A.Object -> Options -> Either
String Options`; `Options` and `commandLineFlags` are untouched.

- Top-level keys are kebab-case mirrors of CLI flag names; repeatable
  flags accept YAML lists. Bad type / unknown key fails fast naming file
  + key, exit 1.
- Discovery (first match wins): `--config=PATH` > `$AGDA_DEPS_CONFIG` >
  `./.agda-deps.yml`(`.yaml`) > walk up to the first ancestor with a
  `*.agda-lib` and pick its dotfile.
- Merge order: **defaults → config → CLI**. A stderr breadcrumb fires
  once when a config applies, unless `--quiet`.

Example:

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

Two CLI simplifications shipped alongside:

- **`--theme=default|light|dark|colorblind`** — single-flag preset for
  the four state colours. Explicit `--color-*=#RRGGBB` still wins. YAML
  `theme:`.
- **Auto-format inference from `-o`** — when `--format` is not set and
  `-o` ends in `.html`/`.json`/`.dot`, the format is inferred. Explicit
  `--format=…` always wins; directories/extension-less names keep the
  default (`dot`).
- **Per-view shortcut flags deprecated** — still work, but emit a
  one-time stderr note; use `--view=NAME`.

Added build-dep `yaml >= 0.11 && < 0.12`.

---

## 2026-05-27 — `agda-deps` — edge-provenance tagging

Expanded JSON now carries an optional `definitionEdgesProvenance` array,
parallel to `definitionEdges`, tagging each edge `signature | body |
where | with | unknown`. `AgdaDeps.Deps`:

- Walks `defType` and `theDef` **separately**.
- Names in `defType` are `Signature`; names in `theDef` are `Body`,
  refined to `With` when the parent's `funWith` points at the target and
  `Where` when the qname's `prettyShow` contains the `._.` marker.
- Combines via precedence `Signature > With > Where > Body > Unknown`.

`ADDef` gained a strict `_depsProv :: !(Map QName EdgeProv)` with the
invariant `M.keysSet _depsProv == _deps`. `IgnoredEdgeMap` was widened to
carry provenance through `contractIgnoredEdges` — contracted edges
inherit the **source** side's tag. Packed mode emits an `Int8` array
parallel to `outTargets` (`0=signature,1=body,2=where,3=with,4=unknown`).
Schema stays at `v=2`; the field is additive.

---

## 2026-05-27 — `agda-deps` — lazy-mode placeholder detail files for modules with no kept defs

`--lazy` declared `moduleFiles[m]` entries for modules whose detail JSON
was never written (externals like `Agda.Primitive`, and project modules
where every def was filtered), so the JS fetched a 404. Root cause:
`buildGraphJson` populated `moduleFiles` for every module, but
`buildModuleDetails` only emitted files for modules with entries in
`defsByModule`.

Fix: `buildModuleDetails` now emits a stub detail JSON for every module
in `moduleFiles` absent from `defsByModule`, with discriminators
`placeholder: true`, `reason: external|filtered|failed`, and optional
`externalPostulates`. Eight view templates gained
`placeholderReasonText` + `renderPlaceholderHTML` and a guard at the
fetch site. Schema stays at `v=2`; non-lazy and expanded modes unaffected.

---

## 2026-05-26 — `agda-deps` — `--no-externals` actually drops externals + `externals_summary`

### `--no-externals` actually drops externals

`--no-externals` was still emitting hundreds of stdlib module names. Root
cause: `classifyExternalModules` derived its external set only from
QNames with a resolvable source path, but Agda's compiler-builtins carry
`rangeFile = Nothing`, and stdlib modules visible only as import-edge
endpoints had no surviving QName.

Fix: `classifyExternalModules` now takes three signals — QNames,
`precomputedModuleFiles`, and all import-edge endpoint module names —
and treats a module as external when *no* signal places its source under
the project root. The `keep` predicate is applied to `moduleFileMap` too
(the single source of truth for module-level wire filtering) so
`moduleFiles` can't leak an external path. Default output unchanged.

### `externals_summary` top-level field

A new top-level `externals_summary` tags dropped externals so a
diagnostic record of the trusted base survives `--no-externals`.
Collected *before* `dropExternalDefs` runs; omitted entirely when
`--no-externals` is off (byte-identical otherwise).

```json
"externals_summary": {
  "modules": ["Agda.Builtin.Bool", "Agda.Primitive", ...],
  "postulates_by_module": {
    "Agda.Builtin.Bool": ["true", "false"],
    ...
  }
}
```

`buildExternalsSummary` filters defs by `state == Postulate`, groups
unqualified names by module, and feeds both packed and expanded output.
The `--skip-agda` path initialises it to `Nothing` (no postulates seen).

---

## 2026-05-26 — `agda-deps` — per-definition `line`, `access`, instance reverse edges

- **`line` per definition** — `_line :: !(Maybe Int)` via
  `nameBindingSite` → `rStart` → `posLine`. Emitted in expanded JSON
  (omitted when unknown); packed unchanged.
- **`access` per definition** — `_access :: !(Maybe DefAccess)`. Agda
  discards the per-decl `Access` tag after scope-checking, so this uses a
  source-level pre-scan (`findPrivateRanges`) for top-level `private`
  blocks at column 0; `backfillAccess` matches each def's `_line` against
  those ranges. Emitted as `"access": "private" | "public"`.
- **Instance-declaration reverse edges** — new `methodProvidersRef`
  side-channel. `recordInstanceMethods` (in `compileDefAD`) records
  `defInstance` binders + projection-method QNames off head clause
  patterns; `addInstanceMethodEdges` (after `contractIgnoredEdges`)
  appends providers to any kept def's dep that's a method key. Additive.

---

## 2026-05-25 — `agda-deps` — node-identity and dead-private recovery fixes

- **`ignoreDef` filters every `defCopy`** — module-instantiation copies
  for `Record`/`Datatype`/`Constructor`/`Projection`, not just
  `Function`; previously surfaced as ghost entries under the importer.
- **`hashQName` via `prettyShow`** — was hashing derived-`Show`, which
  included `NameId` metadata that differs between `iSignature` and
  `stSignature` sources, collapsing duplicate nodes.
- **Dead-end private definition recovery in `postModuleAD`** — Agda's
  `eliminateDeadCode` prunes unreachable top-level `private` defs from
  `iSignature`; we diff `getSignature` (pre-prune) against visited QNames
  and feed missing defs through `compileDefAD`.

---

## 2026-05-23 — Feature batch for re-exports / kind / edge contraction

### Edge contraction through ignored defs

Headline correctness fix: `with-`clauses elaborate to `parent →
with-NNN → target`, and `ignoreDef` was dropping the `with-NNN` and
losing the edge. `ignoredEdgesRef` records the raw out-edges of every
ignored def; `contractIgnoredEdges` (in `postCompileAD`) rewrites each
kept def's `_deps` by expanding hidden refs into their transitive
non-hidden targets, via a topsort-based DP (Kahn) linear in hidden-node
count. Side-effect: `ignoreDependency` filtering moved from
`computeDefAD` to `contractIgnoredEdges` so raw hidden refs survive to be
expanded. Roughly doubled edge counts on the reference corpus.

### `kind` discriminator on definitions

Each `ADDef` carries `_kind :: !DefKind` derived structurally from
`theDef`: `function`/`projection`/`datatype`/`record`/`constructor`/
`postulate`/`primitive`/`other`. Emitted in expanded JSON so consumers
filter without string-scraping qnames. Agda 2.9's `funProjection` is
`Either ProjectionLikenessMissing Projection`; projection matches
`Right{projProper = Just _}`.

### `reexports[]` in expanded JSON

Captures `open import M public` and parameterised-module re-exports. The
producer walks each visited `Interface`'s `iScope` over both
`ImportedNS` (plain `open … public`) and `PublicNS` (re-exports through
parameterised applications) namespaces. `iScope` is reconstructed from
`iInsideScope` at deserialise time, so the data survives cached `.agdai`.

---

## 2026-05-22 — G12 · external feature-request batch

Shipped 9 of 14 items from an external feature-request batch; the rest
are in [Backlog.md](Backlog.md).

- `--version` / `-V` / `--numeric-version` — early intercept in `Main`;
  reports the backend's version, not Agda's.
- `--quiet` — silences progress chatter via `AgdaDeps.Logging.info`,
  backed by a global `quietRef`.
- `--no-externals` — drops external modules from the rendered graph.
- `--json-mode=packed|expanded` — selects `--format=json` shape.
  Expanded ships `definitions` as `[{id, name, module, state, x?, y?}]` +
  string edge pairs + explicit `schemaVersion` and `mode`.
- `--lenient-imports` — rewritten in `Main.hs` to
  `--allow-unsolved-metas`; useful with `--keep-going` on projects with
  deliberate `?` holes.
- `-o` directory auto-created via `createDirectoryIfMissing True`.
- `Options` grew `JsonMode`, plus `optQuiet`, `optNoExternals`,
  `optJsonMode`, `optLenientImports`.
- `CLAUDE.md` gained the "State semantics" (D/P/H/F) and "v2 graph.json
  schema" sections.

---

## G11 — `--skip-agda`

Short-circuits the entire Agda pipeline. `Main.hs` routes `--skip-agda`
to `AgdaDeps.SkipAgda.runSkipAgda`, consuming the line-parsed `module …`
/ `import …` declarations `AgdaDeps.Precompute` already produces.

- Backend options parsed via `getOpt' Permute` + `runOptM`.
- `Precompute.parseHeader` falls back to `takeBaseName path` for
  `module _ where`.
- `GraphInput` got `giExtraModules :: Set String` so orphan modules
  appear; `renderHtmlFromInput` exposed for `SkipAgda`.

Trade-off: no def graph, no D/P/H, no snippets. Module-DAG views render;
def-level views show empty pods. Runs in milliseconds regardless of size.

---

## G10 — Scaling to ~1M defs / 100k modules

Audited the pipeline for O(n²) hot spots; switched to strict
`Map`/`IntMap`/`IntSet`/`Set` folds throughout. Byte-identical output.

- `Layout.moduleGrouped` — `IntMap` cons-accumulation (was
  `M.fromListWith` with `(++)`).
- `GraphJson.bfsFrom`/`bfsDepths` — `Data.Sequence` instead of list queues.
- Six `nub` sites collapsed to Set-based dedup.
- `moduleEdgePairs` — folds into `Set (Int, Int)`.
- `Deps.collectAllQNames` — folds into `IntMap QName`.
- `Csr.buildCsr` — fused `length` + `concatMap` into one strict sweep.
- `Backend.computeQNamePositions` — `IntSet`/`IntMap`, cheap membership
  test first.
- `moduleStateCounts` — strict `data Counts !Int !Int !Int !Int`.
- `buildSearchIndex` bigrams gated above 50k names; JS falls back to
  linear scan.

---

## G9 — Multi-view HTML system

Replaced the single cytoscape template with a `View` ADT and one template
per view under `src/AgdaDeps/templates/views/`, all consuming the same v2
`graph.json`:

- `module-dag-pods` *(default)* — top-down DAG of expandable module pods
  via dagre.
- `cytoscape` — original compound-node viewer.
- `ide-three-pane`, `source-centric`, `notion-doc`, `wiki-backlinks` —
  definition-level views.
- `sigma` — WebGL via sigma.js + graphology + dagre; falls back to
  concentric above 3000 modules.
- `big-module-dag-pods` — viewport-virtualised port for ~100k modules.
  Dagre layout pre-computed Haskell-side (`buildModuleDagLayout`, Kahn +
  column-pack, O(V+E)), packed as `modulePodLayout`; JS uses a
  spatial-grid + minimap.
- `progress-dashboard`, `critical-path-holes` — KPI / kanban dashboards.
- `sunburst-hierarchy`, `cartographic-atlas`, `reading-order-narrative`,
  `pixel-grid-overview` — hierarchical / textbook / heatmap views.

---

## G8 — Custom `--help` (`AgdaDeps.Help`)

Agda's own `--help` lists hundreds of flags. `Main.hs` intercepts plain
`--help` / `-h` / `-?` and routes to `printHelp`, which uses
`usageInfo` over only the backend's `commandLineFlags`. Topic forms
(`--help=warning`) still forward to Agda; new `--agda-help` is rewritten
to plain `--help` for Agda's upstream printer.

---

## G7 — Partial compilation under `--keep-going`

`Agda.Main.runAgda` aborts on the first `TCErr`, so `postCompile` never
fires. Forked into `AgdaDeps.ModuleExplorer`:

- `partialBackendInteraction` catches `TCErr` from `check mainFile`,
  records the failing module via `reportFailed :: String -> IO ()`, and
  drives each backend manually over the modules Agda did load.
- `partialCompilerMain` re-seeds `stVisitedModules` from
  `stDecodedModules`, runs `preCompile`, then `postCompile`.
- `AgdaDeps.Driver` is a thin shim wiring `failedModulesRef` to the callback.

---

## G6 — Auto-discover `.agda-lib` for non-cwd invocations

Plain `agda` only looks for `.agda-lib` in cwd, so invocations from
outside the project failed (library deps never consulted). Pre-process
argv before `runAgdaArgs`: canonicalize path-bearing entries to absolute
paths first (so a relative `-o foo/` resolves against the user's cwd),
then walk up from each `-i` and each `.agda`/`.lagda*` positional for an
ancestor containing a `*.agda-lib` and `setCurrentDirectory` to it. Skip
the dance when `--no-libraries`, `--library`/`-l`, or `--library-file` is
already passed.

---

## G5 — Bump to Agda 2.9

- `cabal.project` pins Agda as a `source-repository-package` from
  `github.com/agda/agda` (2.9.0 isn't on Hackage yet).
- `agda-deps.cabal`: `Agda >= 2.9 && < 3`.
- `graphviz >= 2999.20` to dodge older versions' `<>` ambiguity on GHC ≥ 9.
- Adapted `_funWith :: Maybe QName` → `IsWithFunction QName` via `isWithFun`.

---

## G4 — Linked source view (`--with-source`)

`--with-source` embeds each definition's source in a slide-in drawer,
rendered with Agda's native semantic highlighting. Drives Agda's
`defaultPageGen` programmatically from `postCompileAD`:

1. Per-module Agda HTML to a temp dir under `-o`.
2. Extract the `<pre class="Agda">` block from each file.
3. Per leaf QName: find binding line via `srcLocOf`, compute paragraph
   bounds against the cached source, slice the highlighted HTML by line.
4. Inline `source` + `sourceLine` on each node's JSON; remove temp dir.

Line slicing is safe because Agda's rendered `<pre>` keeps newlines as
plain text *outside* any `<a>` tag.

---

## G3 — Node colouring by state

Definitions classified `Defined` / `Postulate` / `Hole`, tagged on
`ADDef`. Palette via `--color-defined` / `--color-postulate` /
`--color-hole` (defaults `#4caf50` / `#f44336` / `#9c27b0`); both DOT and
HTML honour it. Hole detection has three signals because Agda's
`openMetasToPostulates` rewrites `?` into synthetic `unsolved#meta.*`
postulates before backends fire: a syntactic `MetaV` walk, the def's own
name, and references to synthetic-meta names.

---

## G2 — HTML interactive backend

Added `--format=dot|html` and a self-contained browser-explorable HTML
output backed by [cytoscape.js](https://js.cytoscape.org/). Modules as
collapsible compound parent nodes (`cytoscape-expand-collapse`); cytoscape
loaded from CDN, graph inlined as JSON. Output routed via `-o/--out-dir`.

---

## G1 — Remove nix scaffolding

Stripped `flake.nix` / `flake.lock`. Project builds purely via `cabal`.
