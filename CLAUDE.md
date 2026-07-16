# CLAUDE.md

Guidance for Claude Code in this repository.

## Project overview

`agda-deps` is an Agda compiler backend (not a standalone tool) that emits a
graph of lemma / definition dependencies. It registers as a `Backend` via
`Agda.Main.runAgda`, so it runs inside Agda's type-checking pipeline and is
driven through the Agda CLI.

Outputs:

- **DOT** (Graphviz)
- **HTML** (self-contained or `--lazy` split-files; one of several *views* —
  `module-dag-pods` default, `cytoscape`, `sigma`, `big-module-dag-pods`,
  dashboards, hierarchical, …)
- **JSON** (v2 `graph.json`, `packed` or `expanded`)

Each node is coloured by state — `D`efined / `P`ostulate / `H`ole / `F`ailed
(see [State semantics](#state-semantics)). The emitted `graph.json` is a stable
wire artifact for downstream tooling; its [v2 schema](#v2-graphjson-schema) is
the contract.

End-user docs: [README.md](README.md). History: [Changelog.md](Changelog.md).
Planned / deferred work: [TODO.md](TODO.md), [Backlog.md](Backlog.md).

## Build / run

```
cabal build
cabal run agda-deps -- -i test/ -o test/ test/Test.agda
```

`--` separates cabal flags from backend arguments. After `--`, flags are Agda
CLI flags (`-i` include path; trailing positional is the module). Backend flags
live in `commandLineFlags` (`src/AgdaDeps/Backend.hs`) and [README.md](README.md).

Stable on-`PATH` binary: `cabal install exe:agda-deps --overwrite-policy=always`.
`agda-deps --version` prints the full build fingerprint (version + git rev +
date + GHC) — the same string stamped into `graph.json` as `"producer"`.
`--numeric-version` stays the bare number.

No test suite or lint config. Exercise the backend against `test/` (entry
`test/Test.agda`). CI (`.github/workflows/ci.yml`) builds and runs `dot` /
`html` / `html --lazy` / `json` over this corpus.

Two side-channels skip parts of the pipeline:

- `--keep-going` — catches type-check errors and proceeds with whatever modules
  loaded (`ModuleExplorer`; failing module tagged `F`).
- `--skip-agda` — skips Agda entirely; renders a module-level graph from the
  source scan (`SkipAgda` + `Precompute`).

## Module map

```
src/Main.hs               argv pre-processing, .agda-lib discovery, dispatch
                          to runSkipAgda / runAgdaArgsKeepGoing / runAgdaArgs.
src/BuildInfo.hs          Compile-time build identity (version + git rev +
                          date + GHC); surfaced in --version and graph.json
                          "producer".
src/BuildInfoTH.hs        TH helper behind BuildInfo (split out for the stage
                          restriction): captures the git revision at build time.

src/AgdaDeps/
  Backend.hs              Backend' record + hooks (moduleSetup, compileDefAD,
                          postModuleAD, postCompileAD); CLI flag list;
                          post-compile dispatcher; dropExternalDefs,
                          collectReExports, classifyExternalModules.
  Driver.hs               Thin shim exposing runAgdaArgsKeepGoing.
  ModuleExplorer.hs       --keep-going glue: a backendInteraction drop-in that
                          catches check failures (via catchAllTCM) and, on the
                          failure branch, re-drives the hooks over every decoded
                          interface (rebuilding import state via mergeIfaceState)
                          so postCompile gets def-level data for every elaborated
                          module. Every stage guarded; postCompile always runs.
  FragmentCache.hs        --incremental per-module fragment cache
                          (Data.Binary-serialised ADDefs + side-channel slices),
                          keyed on iFullHash + option fingerprint + nodeKeyVersion.
                          Works on both Agda 2.8 and 2.9 (identity is the
                          serialisable NodeRef, not a QName — no EmbPrj, no CPP).
                          Also gcFragments.
  SerialiseCache.hs       --incremental serialise: a plain-text manifest of
                          content epochs, letting a rebuild skip re-emitting
                          unchanged output (monolithic + per-module lazy skips).
  LibResolve.hs           --resolve-deps: parses the .agda-lib + Agda's libraries
                          registry, walks the depend: closure, returns the
                          '--no-libraries -i <dir> …' argv. Wired in Main.hs
                          before Agda's CLI parser.
  SkipAgda.hs             --skip-agda entry point.
  Precompute.hs           Line-scan for module / import declarations.
  Help.hs                 --help / --version intercepts.
  Logging.hs              quietRef + info.
  Options.hs              Options record, defaultOptions, parsers, View, JsonMode.
  Config.hs               YAML config loader for .agda-deps.yml (kebab-case
                          mirror of the CLI flags) + discovery + applyConfig +
                          theme presets.
  Deps.hs                 ADDef, compileDefAD, classifyDef, ignoreDef,
                          ignoredEdgesRef, contractIgnoredEdges.
  Layout.hs               (x, y) positions per definition.
  Csr.hs                  CSR adjacency + base64 serialisation.
  Source.hs               --with-source machinery.
  TermCanon.hs            --with-term-hashes: canonicalises each elaborated
                          subterm (de-Bruijn indices, positions stripped, MetaV
                          identities wildcarded, Hiding kept) to a Word64.
  Util.hs                 isWithFun, jsString + JSON encoders, dedupOrd,
                          hex-colour parsing, argv inspection.
  Backend/
    Wire.hs               Single source of truth for the v2 *expanded* wire
                          shape: field tables + SchemaDoc ADT. Generates the
                          JSON Schema (--emit-schema) and encodes the output
                          (encodeExpanded); owns the expanded wire tags.
    GraphJson.hs          v2 graph.json emitter. Packed + --lazy hand-rolled
                          here; expanded's buildExpandedJson builds an
                          ExpandedGraph and defers encoding to Wire, so its
                          field set IS Wire's by construction.
    Html.hs               renderHtml / renderLazyHtml + renderHtmlFromInput
                          (used by SkipAgda). templateRawFor.
    Dot.hs                Graphviz DOT renderer.
    Json.hs               --format=json output.
  templates/
    *.html.tmpl           Legacy cytoscape template.
    views/*.html.tmpl     One per view; embedded at compile time via
                          Data.FileEmbed.embedStringFile.
```

## Backend pipeline

```
moduleSetup       captures the module's in-scope QNames (ModuleEnv).
compileDefAD      per Definition: filter via ignoreDef, walk defType + theDef
                  (namesIn) for dep QNames, classifyDef tags state, classifyKind
                  tags kind. Records ignored defs' raw out-edges in
                  ignoredEdgesRef.
postModuleAD      diffs getSignature (pre-prune) vs visited QNames to recover
                  dead-end private defs that eliminateDeadCode pruned; feeds them
                  through compileDefAD. Captures the entry module on the IsMain
                  pass.
postCompileAD     aggregate ADDefs; contractIgnoredEdges rewrites kept defs' deps
                  by expanding hidden refs into their transitive non-hidden
                  targets; dispatch on optFormat to renderDot / renderHtml{,Lazy}
                  / renderJson.
```

## Hard-won gotchas (don't revert)

- **`ignoreDef` is the single source of truth** for real definition vs
  compiler-generated noise. Node-set changes go here; rendering-only changes
  (colour, snippet, label) go in `computeDefAD` / `postCompileAD`.

- **`ignoreDef` short-circuits on `defCopy` before inspecting `theDef`.**
  Module-instantiation copies exist for `Record` / `Datatype` / `Constructor` /
  `Projection`, not just `Function` — without the short-circuit, ghost defs
  surface in the importing module.

- **Keep `ignoreDef`'s `funInline` drop.** Agda inlines every `{-# INLINE #-}`
  call into the caller during type-checking, so the elaborated `Defn` has zero
  incoming edges; as a node it is a permanent false-`dead` orphan. Call edges
  are unrecoverable post-elaboration (fixture `test/InlineGap.agda`); the fix is
  a consumer-side source scan.

- **Scope is captured per-module in `moduleSetup`** (`getCurrentScope`), not
  per-definition. Don't move it.

- **Filter `ignoreDependency` once in `contractIgnoredEdges`** (on the contracted
  set), not per-def: raw hidden refs must survive for the contraction pass to
  expand them, else edges through with-/where-helpers are lost.

- **Node identity is a `NodeRef`, built once at the producer boundary.**
  `ADDef` and both side-channels are keyed by `NodeRef` (a precomputed,
  `Data.Binary`-serialisable bundle: `nodeKey` string + hash + `moduleKey` +
  line + file + `prettyShow` + a precomputed `ignoreDef` flag), *not* a live
  `QName`. `mkRef :: QName -> TCM NodeRef` does the conversion (the only
  `getConstInfo` is folded into `nrIgnorable` here, so `contractIgnoredEdges`
  needs no TCM and cache-hit defs need no live QName). The `...OfQ` helpers
  (`nodeKeyOfQ` / `moduleKeyOfQ`) are the QName-level logic, used only by `mkRef`
  and the producer-side sites that see live interface QNames (dead-private
  recovery, `collectReExports`). This is why the fragment cache is a plain
  `Data.Binary` payload with no `EmbPrj`/CPP and works on 2.8.
- **Node identity string is `nodeKey`** (`hashQName = hashString . nodeKey`,
  via `NodeRef`); the wire `"name"` and all edge endpoints derive from it, and
  the expanded-edge filter resolves by the canonical string, not `NodeRef`/`QName`
  `Ord`. Not the alternatives:
  - derived `Show` carries `NameId` metadata that differs between `iSignature`
    and `stSignature` sources — can't key nodes;
  - `prettyShow` alone over-collapses same-named `where`/anonymous-module helpers
    onto one node. `nodeKey` disambiguates `._.` helpers with an `@<line>`
    suffix, and lifts anonymous-module segments (`Mod._.helper@15` ↦
    `Mod.helper@15`) via `Util.liftAnonSegments`. Post-scope-check `where` and
    `module _ (…) where` are identical — don't try to tell them apart.
  - **Every QName→module-string site routes through `moduleKey`**
    (`liftAnonSegments . prettyShow . qnameModule`): externals, `--exclude`,
    module DAG, manifests, DOT clusters — else phantom `Mod._` nodes and false
    cycles appear.
  Regressions: `test/Collision.agda`, `test/AnonSection.agda`.

- **`nodeKeyVersion` tracks the node-naming convention** and is stamped into
  `graph.json` so a consumer can spot a stale-format cache. Bump it whenever
  `nodeKey` changes shape (currently **3**). The consumer repo
  `agda-graph-explorer` reads the same constant — a bump is a cross-repo
  coordination point.

- **`BuildInfo` is split in two for the TH stage restriction:** the git-rev
  splice generator lives in `BuildInfoTH` (GHC forbids a splice using a generator
  from the same module); `BuildInfo` does the splice + CPP date + version. The
  `built` date freezes across an uncommitted rebuild that doesn't recompile
  `BuildInfo`, so the reliable discriminator between two dirty builds is the
  binary's *mtime*.

- **Output routing.** DOT / JSON → `<outDir>/deps.dot|.json`, else stdout. HTML →
  `<outDir>/deps.html` and errors if `optOutDir` is unset. `postCompileAD`
  creates `optOutDir`.

- **Agda 2.8 / 2.9 coupling.** `Agda >= 2.8 && < 3`. The default `cabal.project`
  pins `Agda ==2.8.0` from Hackage (system GHC 9.12.4); `cabal.project.agda29`
  pins a 2.9 upstream git commit (2.9.0 isn't on Hackage) and builds the 2.9
  variant (`cabal build --project-file=cabal.project.agda29
  --builddir=dist-agda29 agda-deps`). The solver picks the Agda — no flag. Both
  are gated in CI (the `build` and `build-agda29` jobs) against the same golden.
  API deltas are bridged with CPP on `MIN_VERSION_Agda(2,9,0)` in five modules:
  - `Util.hs` — `funWith` is `Maybe QName` (2.8) vs `IsWithFunction QName` (2.9).
  - `Help.hs` — `usageInfo` gained a leading column-width arg in 2.9.
  - `Main.hs` — 2.8 has no `runAgdaArgs`; shimmed via `withArgs` + `runAgda'`.
  - `Backend.hs` — `anameName` in `Scope.Base` (2.8) vs `Abstract.Name` (2.9).
  - `ModuleExplorer.hs` — `stCurrentModule` lazy `Maybe` (2.8) vs strict `:!:`
    (2.9); `setTCLens' stBackends` (2.8) vs `setSession lensBackends` (2.9).
  In these CPP modules, don't use backslash string gaps (cpp collapses them) —
  use `++`. Agda 2.9's `funProjection` is `Either ProjectionLikenessMissing
  Projection` — match `Right{projProper = Just _}`. Both builds produce
  byte-identical graphs (modulo `producer`).

- **`Main.hs` argv pre-processing** canonicalizes path-bearing flags (`-o`, `-i`,
  `--include-path`, `--out-dir`, `.agda`/`.lagda*` positionals) to absolute
  paths, then `setCurrentDirectory` to the nearest ancestor with a `*.agda-lib`.
  Skipped under `--no-libraries` / `--library` / `-l` / `--library-file`. Lets
  users run from outside the source dir without losing library deps, and makes
  `classifyExternalModules`'s cwd-prefix check work.

- **Adding a flag.** Extend `Options` + `commandLineFlags` **and** `Config.hs`'s
  `applyConfig` (kebab-case YAML mirror) **and** `NFData Options`. Merge order:
  defaults → config → CLI. Don't add a second config mechanism.

- **Adding a view.** Extend `View`; add `viewSlug` + `viewOpt` cases; add the
  template to `extra-source-files` in `agda-deps.cabal`; add the `templateRawFor`
  line. The surface is `--view=NAME` / YAML `view: NAME` only — no `--<slug>`
  shortcut.

- **Config discovery order:** `--config=PATH` > `$AGDA_DEPS_CONFIG` >
  `./.agda-deps.yml` (or `.yaml`) > walk up to the nearest `*.agda-lib` dotfile.
  Merge: defaults → config → CLI. Top-level keys are kebab-case CLI flag names.
  Bad type / unknown key errors with file + key and exits 1.

- **`--theme` is a colour preset** — resolves to the four state colours
  (`color-defined` / `-postulate` / `-hole` / `-failed`); explicit `--color-*`
  flags win. Adding a theme is a tuple in `Config.hs` — don't grow `View` /
  `Options`.

- **Auto-format from `-o`.** With no `--format`, a `.html` / `.json` / `.dot`
  `optOutDir` infers the format (explicit `--format` wins; directories keep the
  default `dot`). Inference lives in `Main.hs` argv pre-processing — don't
  duplicate it in the backend.

- **Scaling.** Prefer strict `Map` / `IntMap` / `IntSet` / `Set` folds; avoid
  `(++)` queues (use `Data.Sequence` for BFS); `BangPatterns` on `foldl'`
  accumulators.

- **Single-threaded on purpose.** Agda's `TCM` and its `IORef` state aren't
  thread-safe and the `Backend'` hooks run serially. No `parMap` / `forkIO` /
  `Async` under `src/AgdaDeps/`.

- **Edge provenance (producer side).** `computeDefAD` (`Deps.tagOne`) walks
  `defType` and `theDef` separately: `defType` names → `Signature`; `theDef`
  names → `Body`, refined to `With` when the parent's `funWith` points at the
  target and `ModuleLocal` (wire `module-local`) when the qname's `prettyShow`
  contains `._.`. `module-local` is a property of the *target*, not the (src,
  dst) pair. Precedence: `Signature > With > ModuleLocal > Body > Unknown`.
  Contracted edges inherit the source side's provenance; `addInstanceMethodEdges`
  adds `Unknown` with a left-biased `M.union`. Invariant: every kept edge has
  exactly one tag and `M.keysSet _depsProv == _deps` at every `ADDef`.

- **Clauses are all `noRange` post-`KillRange`** — count them with `funCompiled`
  (`CompiledClauses`), not `clauseLHSRange`.

- **The partial pass guards with `catchAllTCM`, not `catchError`.** Agda's
  `__IMPOSSIBLE__` is a GHC exception, not a `TCErr`, so `catchError` can't catch
  it. `catchAllTCM` (TCErr + GHC exceptions; re-throws `ExitCode` + async) guards
  every stage. `catchError` also rolls back the whole `TCState`, so
  `partialCompilerMain` rebuilds import state from the decoded interfaces via
  `mergeIfaceState` (signature alone drops builtins → breaks `--with-signatures`
  reification): builtins with per-prim rebinds, remote metas, pattern synonyms,
  display forms. Pass `NotMain` to every module (`IsMain` makes `entryModule`
  record whichever ran last). Locked by `test-keepgoing/` + CI.

- **Regenerate the golden from a COLD run** (`rm -f test/*.agdai` first — CI
  does). A warm main module skips the `getSignature` dead-private recovery and
  emits a poorer graph. Main-module-only: `stSignature` holds only the entry
  module's defs at backend time, so imported modules are cache-independent.

- **`--incremental` fragment invariants.** Fragments must carry the module's
  `ignoredEdgesRef` + `methodProvidersRef` contributions — a `Skip`ped module
  never runs `compileDef`, so without them `contractIgnoredEdges` loses every
  edge through its with-/where-helpers. The slices must be before/after
  `ModuleEnv` deltas, not name-prefix filters: Agda homes module-instantiation
  copies at bare `_.…`/prefixless QNames no interface name prefixes.

- **`--packed-analytical` parity is by construction; `access` is 3-valued.** The
  analytical packed arrays (`kinds` / `lines` / `access` / `types` / subterm CSR)
  must agree node-for-node with expanded. Parity comes from sharing the per-QName
  lookups (`mkDefKind` / `mkDefLine` / …) between `toExpandedGraph` and
  `buildGraphJson` — don't inline them per-form. `access` stays 3-valued
  (`0`=unknown/absent, `1`=public, `2`=private): expanded omits `access` / `line`
  / `type` for QNames with no local `ADDef`, and `0` round-trips to that
  omission. Gate: `schema/packed_analytical_check.py` (run both sides cold).

- **`--incremental` serialise skip (`SerialiseCache`).** The monolithic no-op
  skip needs BOTH guards: `not anyRecompiled` (per-def content) AND a matching
  `outputToken` (module set + output-affecting options + build identity). Drop
  either and it serves stale output, so `outputToken` must list every
  output-affecting option (same discipline as `NFData Options`). The lazy
  per-module skip is content-epoch based (`mdjEpoch`). Fragment serialisation is
  plain `Data.Binary` over the `NodeRef`-keyed payload (works on 2.8 and 2.9
  alike — no `EmbPrj`, no CPP). Bump `fragmentFormatVersion` on a payload-shape
  change; `optionsFingerprint` must list every flag that changes fragment
  content. Disabled under `--keep-going`.

## State semantics

Every definition carries one of four states:

- **`D` Defined.** Elaborated normally: a `Function` with clauses, a `Datatype`,
  `Record`, `Constructor`.
- **`P` Postulate.** Body is `Axiom{}` — user `postulate` or an Agda primitive.
  Type-level promise, no operational content.
- **`H` Hole.** Contains an unsolved meta. Signals: the QName starts with
  `unsolved#meta.` (Agda's `openMetasToPostulates` rewrites `?` under
  `--allow-unsolved-metas`), the def references such a name, or a walk of
  `defType`/`theDef` finds an open `MetaV`. The synthetic-name path is the one
  that fires in practice — by backend time Agda has rewritten user `?`s.
- **`F` Failed.** **Module-level**, not def-level. Synthesised by `--keep-going`
  when a module's type-check raised `TCErr`: a marker node carrying the module
  name. Read as "we tried; contents not available" — neither absent nor
  trustworthy.

Wire encoding: packed → `Int8` byte (0/1/2/3); expanded + the HTML-consumed
`graph.json` → letter `"D"` / `"P"` / `"H"` / `"F"`.

**Soundness escapes are orthogonal to `state`.** Escapes beyond
postulates/holes — a `{-# NON_TERMINATING #-}` function or a `primTrustMe` body —
go in a separate optional per-def `unsafe` array (`UnsafeTag` in `Deps.hs`; wire
tags `non-terminating` / `trustme` in `Wire.hs`). Always computed, omitted when
empty. Emitted in expanded (`unsafe: [...]`) and packed-analytical (an `Int8`
bitmask: bit 0 = non-terminating, bit 1 = trustme). Don't tag
`{-# TERMINATING #-}`: the ordinary termination checker also sets `funTerminates
= Just True`, so it's indistinguishable from a normal proof. Direct-use only;
transitive taint is a consumer query. Fixture: `test/Unsafe.agda`.

**File-level option escapes are module-level.** A whole-module escape via a file
pragma (`{-# OPTIONS --type-in-type #-}`, `--no-positivity-check`, `--rewriting`,
…) is a property of the interface, so it is a separate optional top-level
`moduleOptionEscapes :: Map module [String]` (not folded into the per-def
`unsafe` bitmask). Computed in `postCompileAD` from each interface's
**`iFilePragmaOptions`** (the file's own `OPTIONS` tokens), filtered through
`Deps.optionEscapes` / `safetyRelevantOptionFlags` (Agda's unconditional
single-flag `unsafePragmaOptions` — re-sync on an Agda bump). Use
`iFilePragmaOptions`, not `iOptionsUsed`: the latter folds in command-line +
library defaults and would misattribute e.g. `--lenient-imports` to every module.
Not captured, by construction (pinned by `test/OptionEscapes.agda`): per-block
declaration pragmas (`{-# NO_POSITIVITY_CHECK #-}` — not `OPTIONS`) and
combination-conditional escapes (`--without-K` + `--flat-split`). Omitted when
empty. No CPP: `iFilePragmaOptions` is identical in 2.8 and 2.9.

## v2 graph.json schema

All HTML views consume the v2 schema; `--format=json` emits it directly. The
**expanded** form has a JSON Schema at
[`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json)
(draft 2020-12). `required` covers the fields present since v2 inception;
additive fields (`nodeKeyVersion`, `producer`, `definitionEdgesProvenance`,
`definitionSubterm*`, `externals_summary`, `moduleOptionEscapes`, per-def
`line`/`access`/`type`) are optional and `additionalProperties` is open, so it
validates older and forward-compatible output too. The `packed` form and
`--lazy` layout are not schematised.

**Single source of truth + drift check.** The expanded wire shape is described
once in `AgdaDeps.Backend.Wire` (field tables + a `SchemaDoc` ADT).
`agda-deps --emit-schema` regenerates the schema from it; CI
(`schema/check_schema.py`) fails if that diverges *structurally* (ignoring
`description`/`$id`/`$schema`/`title`) from the committed
`schema/graph-v2-expanded.schema.json`, which is a frozen **oracle** — change the
wire shape in `Wire.hs`, the check fails, you update the oracle deliberately.
Emission goes through the same tables: `buildExpandedJson` builds an
`ExpandedGraph` and calls `encodeExpanded`, which emits only fields in the tables.
So emitted-bytes ≡ `Wire.hs` ≡ committed oracle by construction. Two more guards:
`Wire.validateExpanded` (run by `buildExpandedJson`) asserts cross-array length +
edge-endpoint invariants the schema can't express; and a committed golden
(`test/golden/expanded.golden.json` + `schema/golden_check.py`) catches content
regressions after normalising out build/layout/path-volatile fields. The `packed`
form and `--lazy` layout are hand-rolled in `GraphJson` and not covered here.

Three conventions for downstream consumers:

- **Schema version.** Every payload starts with `"v": 2`; expanded also emits
  `"schemaVersion": 2` and `"mode": "expanded"`. Refuse an unrecognised `v`.

- **Build provenance.** Both forms emit `"producer"` (the emitting build's
  `BuildInfo.buildFingerprint`) and `"nodeKeyVersion"` (the node-key convention).
  Both optional: absent `nodeKeyVersion` parses as `1`. The schema version is for
  wire-shape compatibility; `nodeKeyVersion` is orthogonal — it tracks node
  naming, so a consumer can spot a stale cache whose wire shape is still v2 and
  rebuild.

- **JSON mode** (`--json-mode=packed|expanded`).
  - *packed* — CSR adjacency; per-def state in base64 typed arrays. Best for
    100k+ node projects. See `GraphJson.buildGraphJson`.
  - *expanded* — arrays of records keyed by qname / module name, no base64.
    Carries `schemaVersion` / `mode`, `kind` per definition, and a `reexports[]`
    array. Also an optional `definitionEdgesProvenance` array parallel to
    `definitionEdges` (`signature | body | module-local | with | unknown`);
    always emitted now, absence means "every edge `unknown`". Under
    `--with-signatures` each definition carries an optional `"type"` string (the
    reified type, Agda default printing, no `--show-implicit`; via `prettyTCM`).
    A `reexports[]` row that used `renaming` carries an optional `renames` map
    (`{alias-in-scope: canonical-nodeKey}`), omitted when nothing was renamed.
    Computed by `collectReExports`. Expanded-only — packed / `--lazy` never emit
    `reexports`.

- **Lazy ingest path** (`--lazy`). Wire format split across files:
  - `graph.json` — module-level skeleton: `modules :: [String]`, `moduleEdges ::
    [[Int, Int]]` (index pairs), `moduleFiles :: Map String FilePath` (name →
    `modules/<Module>.json` — **the manifest**; walk it, never derive a URL from
    a module name, since non-safe names fall back to `detail-<hash>.json`), and
    `bundleFiles :: Map String FilePath` (→ `snippets/<Module>.json`, only under
    `--with-source`).
  - `modules/<Module>.json` — that module's defs (`names`, `states`, `x`, `y`)
    plus outgoing leaf edges with `targetModule` annotations. `graph.json` also
    carries the richer module-level fields the views consume (`moduleStates`,
    `moduleDepth`, `modulePodLayout`, `fileTree`/`moduleTree`,
    `transitiveModuleEdges`, CSR `moduleToFile`/`fileToModules`), not yet
    formally schematised.

  Lazy output requires HTTP serving (browsers block `fetch()` on `file://`).

## Reference

- Prior art for the HTML view:
  <https://unimath.github.io/agda-unimath/VISUALIZATION.html>.
