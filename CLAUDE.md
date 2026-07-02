# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project overview

`agda-deps` is an Agda compiler backend (not a standalone tool) that
emits a graph of lemma / definition dependencies for an Agda program.
Registered as a `Backend` via `Agda.Main.runAgda`, so it runs inside
Agda's type-checking pipeline and is invoked through the Agda CLI
surface that `runAgda` provides.

Outputs:

- **DOT** (Graphviz)
- **HTML** (self-contained or `--lazy` split-files; one of several
  *views* — `module-dag-pods` default, `cytoscape`, `sigma`,
  `big-module-dag-pods`, dashboards, hierarchical, etc.)
- **JSON** (v2 `graph.json` schema, `packed` or `expanded`)

Each node is coloured by state — **`D`efined / `P`ostulate / `H`ole /
`F`ailed** (see [State semantics](#state-semantics)).

The `graph.json` it emits is a stable wire artifact for downstream
tooling; the v2 schema (see [v2 graph.json schema](#v2-graphjson-schema))
is the contract.

For end-user documentation see [README.md](README.md). For shipped work
see [Changelog.md](Changelog.md). For forward-looking work see
[TODO.md](TODO.md). For deferred / refused ideas see
[Backlog.md](Backlog.md).

## Build / run

```
cabal build
cabal run agda-deps -- -i test/ -o test/ test/Test.agda
```

`--` separates cabal flags from arguments forwarded to the backend.
After `--`, flags are Agda CLI flags (`-i` include path; trailing
positional is the Agda module). Backend flags are documented in
`commandLineFlags` in `src/AgdaDeps/Backend.hs` and listed in
[README.md](README.md).

For a stable on-`PATH` binary (so callers don't hunt under
`dist-newstyle/`): `cabal install exe:agda-deps
--overwrite-policy=always`. `agda-deps --version` reports the full
build fingerprint (version + git rev + date + GHC) — the same string
stamped into `graph.json` as `"producer"` — so "which build is this?"
needs no mtime/`git log` forensics. `--numeric-version` stays the bare
number for parsing.

No test suite, no lint config. Exercise the backend against `test/` —
entry point `test/Test.agda`. CI (`.github/workflows/ci.yml`) builds
and runs the binary across `dot` / `html` / `html --lazy` / `json`
against this corpus.

Two side-channels skip parts of the normal pipeline:

- `--keep-going` — catches type-check errors and proceeds with whatever
  modules Agda did load (`AgdaDeps.ModuleExplorer`; failing module
  tagged `F` in the graph).
- `--skip-agda` — doesn't invoke Agda at all; renders a module-level
  graph straight from the source-file scan
  (`AgdaDeps.SkipAgda` + `AgdaDeps.Precompute`).

## Module map

```
src/Main.hs                       argv pre-processing, .agda-lib
                                  discovery, dispatch to runSkipAgda /
                                  runAgdaArgsKeepGoing / runAgdaArgs.

src/BuildInfo.hs                  Compile-time build identity for
                                  agda-deps: package version + git
                                  revision + compile date + GHC.
                                  Surfaced in --version and stamped into
                                  graph.json as "producer".
src/BuildInfoTH.hs                TH helper behind BuildInfo (separate
                                  module for the stage restriction):
                                  captures the git revision at build time.

src/AgdaDeps/
  Backend.hs                      Backend' record + hooks
                                  (moduleSetup, compileDefAD,
                                  postModuleAD, postCompileAD); CLI
                                  flag list; post-compile dispatcher;
                                  dropExternalDefs, collectReExports,
                                  classifyExternalModules.
  Driver.hs                       Thin shim around ModuleExplorer
                                  exposing runAgdaArgsKeepGoing.
  ModuleExplorer.hs               --keep-going glue: drop-in for
                                  backendInteraction that catches
                                  check failures (TCErr AND other GHC
                                  exceptions via catchAllTCM). On the
                                  failure branch re-drives preModule /
                                  compileDef / postModule over every
                                  decoded interface (rebuilding the
                                  import state — signature, builtins,
                                  metas, pattern syns, display forms —
                                  via mergeIfaceState first) so
                                  postCompile receives def-level
                                  data for every module that did
                                  elaborate. Every stage guarded:
                                  postCompile always runs.
  FragmentCache.hs                --incremental: per-module fragment
                                  cache (EmbPrj-serialised ADDefs +
                                  side-channel slices), keyed on
                                  iFullHash + option fingerprint +
                                  nodeKeyVersion. Agda >= 2.9 only;
                                  no-op fallback on 2.8. Also
                                  gcFragments (prune stale .frag).
  SerialiseCache.hs               --incremental serialise (P2): a
                                  plain-text manifest of content
                                  epochs in the cache dir, letting a
                                  rebuild skip re-emitting unchanged
                                  output (monolithic no-op skip +
                                  per-module lazy-file skip). No CPP.
  LibResolve.hs                   --resolve-deps machinery: parses
                                  the project's .agda-lib and
                                  Agda's libraries registry, walks
                                  the depend: closure, returns the
                                  '--no-libraries -i <dir> ...'
                                  argv expansion. Wired in Main.hs
                                  before Agda's CLI parser runs.
  SkipAgda.hs                     --skip-agda entry point.
  Precompute.hs                   Cheap line-scan for module / import
                                  declarations.
  Help.hs                         --help / --version intercepts.
  Logging.hs                      quietRef + info :: MonadIO m => …
  Options.hs                      Options record, defaultOptions,
                                  parsers, View ADT, JsonMode.
  Config.hs                       YAML config loader for
                                  .agda-deps.yml (kebab-case schema
                                  mirroring CLI flags); discovery
                                  (--config / $AGDA_DEPS_CONFIG /
                                  dotfile / walk-up to *.agda-lib);
                                  applyConfig :: A.Object -> Options
                                  -> Either String Options. Theme
                                  presets live here.
  Deps.hs                         ADDef, compileDefAD, classifyDef,
                                  ignoreDef, ignoredEdgesRef,
                                  contractIgnoredEdges.
  Layout.hs                       (x, y) positions per definition.
  Csr.hs                          CSR adjacency + base64 serialisation.
  Source.hs                       --with-source machinery.
  TermCanon.hs                    --with-term-hashes: canonicalises
                                  each elaborated subterm (de-Bruijn
                                  indices, source positions stripped,
                                  MetaV identities wildcarded, Hiding
                                  preserved) to a Word64 fingerprint.
  Util.hs                         isWithFun, jsString, dedupOrd,
                                  hex-colour parsing, argv inspection.
  Backend/
    Wire.hs                       Single source of truth for the v2
                                  *expanded* wire shape: field tables
                                  (wire name + SchemaDoc + byte encoder)
                                  + SchemaDoc ADT. Generates the JSON
                                  Schema (`--emit-schema`, CI-diffed vs
                                  the committed schema/ oracle by
                                  schema/check_schema.py) AND encodes the
                                  output (`encodeExpanded`). Owns the
                                  expanded wire tags (wireState/Kind/…).
    GraphJson.hs                  v2 graph.json emitter. Packed + --lazy
                                  are hand-rolled here; expanded's
                                  buildExpandedJson builds an ExpandedGraph
                                  and defers encoding to Wire.encodeExpanded,
                                  so its field set IS Wire's by construction.
    Html.hs                       renderHtml / renderLazyHtml +
                                  renderHtmlFromInput (used by
                                  SkipAgda). templateRawFor.
    Dot.hs                        Graphviz DOT renderer.
    Json.hs                       --format=json output.
  templates/
    *.html.tmpl                   Legacy cytoscape template.
    views/*.html.tmpl             One per view variant.
                                  Embedded at compile time via
                                  Data.FileEmbed.embedStringFile.
```

## Backend pipeline

```
moduleSetup       captures the module's in-scope QNames (ModuleEnv).
compileDefAD      per Definition: filter via ignoreDef, walk defType +
                  theDef via Agda.Syntax.Internal.Names.namesIn for
                  dep QNames, classifyDef tags state, classifyKind tags
                  kind. Records raw out-edges of every ignored def
                  in ignoredEdgesRef.
postModuleAD      diffs getSignature (pre-prune) vs visited QNames to
                  recover dead-end private defs that
                  eliminateDeadCode pruned from iSignature; feeds them
                  through compileDefAD. Captures the entry module on
                  the IsMain pass.
postCompileAD     aggregate ADDefs; contractIgnoredEdges (topsort DP)
                  rewrites kept defs' deps by expanding hidden refs
                  into their transitive non-hidden targets; dispatch
                  on optFormat to renderDot / renderHtml{,Lazy} /
                  renderJson.
```

## Hard-won gotchas (don't revert)

- **`ignoreDef` is the single source of truth** for what counts as a
  real definition vs. compiler-generated noise. Changes to the *set* of
  nodes go here; rendering-only changes (colour, snippet, label) go in
  `computeDefAD` / `postCompileAD`.

- **`ignoreDef` short-circuits on `defCopy` at the top level** (before
  inspecting `theDef`). Module-instantiation copies exist for `Record` /
  `Datatype` / `Constructor` / `Projection`, not just `Function` —
  without the short-circuit, ghost defs surface in the importing module.

- **`ignoreDef`'s `funInline` drop is deliberate — don't remove it.**
  Agda inlines every call to an `{-# INLINE #-}` function into the caller
  during type-checking, so by the time the backend sees the elaborated
  `Defn` the function has zero incoming edges. Keeping it as a node adds a
  permanent zero-caller orphan that dead-code passes flag as a false
  `dead`. The lost call edges are unrecoverable from post-elaboration
  syntax (fixture: `test/InlineGap.agda`); a consumer-side source scan is
  the right fix.

- **Scope is captured per-module in `moduleSetup`** (`getCurrentScope`),
  not per-definition in `compileDefAD`. Don't move it.

- **Filter `ignoreDependency` once in `contractIgnoredEdges`** (on the
  contracted set), not per-def in `computeDefAD`: raw hidden refs must
  survive for the contraction pass to expand them, else edges through
  with-/where-helpers are lost.

- **Node identity is `nodeKey`, never bare `prettyShow` and never derived
  `show`.** `hashQName = hashString . nodeKey`; the wire `"name"`
  (expanded + packed) and edge endpoints all derive from it, and the
  expanded-edge filter resolves by the canonical string, **not** `QName`
  `Ord` (which distinguishes same-`nodeKey` helpers and would re-drop
  their edges). Why not the alternatives:
  - Derived `Show` carries `NameId` metadata that differs between QNames
    sourced from `iSignature` vs `stSignature` — can't key nodes.
  - `prettyShow` alone over-collapses: same-named `where`/anonymous-module
    helpers render identically (`Mod._.name`) and merge onto one node.
    `nodeKey` disambiguates `._.` helpers with a `@<binding-line>` suffix
    (the one per-helper coordinate stable across signature sources).
  - `nodeKey` also lifts anonymous-module segments — the `_` Agda emits
    for both `where` blocks and `module _ (…) where` sections — via
    `Util.liftAnonSegments`: `Mod._.helper@15` ↦ `Mod.helper@15`
    (nodeKeyVersion 3). The edges were already correct (Agda lifts
    enclosing vars into `defType`); the blind spot was naming only. Don't
    try to distinguish `where` from section — post-scope-check they're
    identical.
  - **Every QName→module-string site must route through `moduleKey`**
    (`= liftAnonSegments . prettyShow . qnameModule`): externals,
    `--exclude`, module DAG, manifests, DOT clusters — else set/index
    membership drifts and phantom `Mod._` module nodes + false cycles
    appear.
  Regressions: `test/Collision.agda`, `test/AnonSection.agda` (both
  imported by `test/Test.agda`).

- **`nodeKeyVersion` tracks the node-naming convention.** Stamped into
  `graph.json` so a consumer can detect a stale-format cache and rebuild.
  Bump it whenever `nodeKey` changes shape. Currently **3** (1 = bare
  `prettyShow`; 2 = `@<line>` on `._.` helpers; 3 = anon-module segments
  lifted). The consumer repo `agda-graph-explorer` reads the same
  constant — a bump is a cross-repo coordination point.

- **`BuildInfo` is split across two modules for the TH stage
  restriction.** The git-revision splice generator lives in `BuildInfoTH`
  (GHC forbids a top-level splice using a generator from the same module);
  `BuildInfo` does the splice + CPP date + version. Both are in
  `other-modules` of the `agda-deps` stanza. The `built` date freezes
  across an uncommitted rebuild that doesn't recompile `BuildInfo`, so the
  reliable discriminator between two dirty builds is the binary's *mtime*,
  not the fingerprint.

- **Output routing.** DOT / JSON → `<outDir>/deps.dot|.json`, else
  stdout. HTML → `<outDir>/deps.html` and errors if `optOutDir` is unset.
  `postCompileAD` creates `optOutDir`.

- **Agda 2.8 / 2.9 version coupling.** `Agda >= 2.8 && < 3`. The default
  `cabal.project` pins a 2.9 upstream commit; `cabal.project.agda28`
  (GHC 9.6 + Hackage `Agda ==2.8.0`) builds the 2.8 variant:
  `cabal build --project-file=cabal.project.agda28 --builddir=dist-agda28 agda-deps`.
  The solver picks which Agda — no flag. API deltas are bridged with CPP
  on `MIN_VERSION_Agda(2,9,0)` in five modules:
  - `Util.hs` — `funWith` is `Maybe QName` (2.8) vs `IsWithFunction QName` (2.9).
  - `Help.hs` — `usageInfo` gained a leading column-width arg in 2.9.
  - `Main.hs` — 2.8 has no `runAgdaArgs`; shimmed via `withArgs` + `runAgda'`.
  - `Backend.hs` — `anameName` in `Scope.Base` (2.8) vs `Abstract.Name` (2.9).
  - `ModuleExplorer.hs` — `stCurrentModule` lazy `Maybe (_,_)` (2.8) vs strict
    `:!:` (2.9); `setTCLens' stBackends` (2.8) vs `setSession lensBackends` (2.9).
  **CPP gotcha:** these five modules must not use backslash string gaps
  (cpp collapses `\`-newline) — use `++` concatenation. Note: Agda 2.9's
  `funProjection` is `Either ProjectionLikenessMissing Projection` — match
  `Right{projProper = Just _}`. Both builds produce byte-identical graphs
  (modulo the `producer` fingerprint).

- **`Main.hs` argv pre-processing** canonicalizes path-bearing flags
  (`-o`, `-i`, `--include-path`, `--out-dir`, `.agda`/`.lagda*`
  positionals) to absolute paths, then `setCurrentDirectory` to the
  nearest ancestor containing a `*.agda-lib`. Skipped under
  `--no-libraries` / `--library` / `-l` / `--library-file`. Lets users run
  from outside the source dir without losing library deps, and makes
  `classifyExternalModules`'s cwd-prefix check work.

- **Adding a flag.** Extend `Options` + `commandLineFlags` **and**
  `Config.hs`'s `applyConfig` (kebab-case YAML mirror) **and** `NFData
  Options` (forces every field). Merge order: defaults → config → CLI.
  Don't add a second config mechanism.

- **Adding a view.** Extend `View`; add `viewSlug` + `viewOpt` cases; add
  the template to `extra-source-files` in `agda-deps.cabal`; add the
  `templateRawFor` line. The placeholder contract is documented in the
  templates (copy `sigma.html.tmpl`). Don't add a `--<slug>` shortcut flag
  — the surface is `--view=NAME` / YAML `view: NAME` only.

- **Config discovery order:** `--config=PATH` > `$AGDA_DEPS_CONFIG` >
  `./.agda-deps.yml` (or `.yaml`) > walk up to the nearest `*.agda-lib`
  and use its dotfile. Merge: defaults → config → CLI. Top-level keys are
  kebab-case CLI flag names. Bad type / unknown key errors with file + key
  and exits 1. A stderr breadcrumb fires when a config applies (unless
  `--quiet`).

- **`--theme` is a colour preset.** It resolves to the four state colours
  (`color-defined` / `-postulate` / `-hole` / `-failed`) in `Options`;
  explicit `--color-*` CLI flags layer on top and win. Adding a theme is a
  tuple in `Config.hs` — don't grow `View` or `Options`.

- **Auto-format from `-o`.** When `--format` is not set and `optOutDir`
  ends in `.html` / `.json` / `.dot`, the format is inferred from the
  extension (explicit `--format` wins; directories/extensionless keep the
  default `dot`). Inference lives in `Main.hs` argv pre-processing — don't
  duplicate it in the backend.

- **Scaling.** Prefer strict `Map` / `IntMap` / `IntSet` / `Set` folds;
  avoid `(++)` queues (use `Data.Sequence` for BFS); `BangPatterns` on
  `foldl'` accumulators.

- **`agda-deps` is single-threaded on purpose.** Agda's `TCM` and its
  `IORef`-backed state aren't thread-safe and the `Backend'` hooks are
  called serially. Don't add `parMap` / `forkIO` / `Async` under
  `src/AgdaDeps/`. (Post-Agda IO in `postCompileAD` would be safe to
  parallelise — deferred.)

- **Edge provenance (producer side).** `computeDefAD`
  (`AgdaDeps.Deps.tagOne`) walks `defType` and `theDef` separately:
  `defType` names → `Signature`; `theDef` names → `Body`, refined to
  `With` when the parent's `funWith` points at the target and
  `ModuleLocal` (wire tag `module-local`) when the qname's `prettyShow`
  contains the `._.` marker. `module-local` is a property of the *target*
  (an anonymous-module-local helper), not the (src, dst) pair. Precedence:
  `Signature > With > ModuleLocal > Body > Unknown`. Contracted edges
  inherit the **source** side's provenance toward the hidden helper;
  `addInstanceMethodEdges` adds `Unknown` with a left-biased `M.union`.
  Invariant: every kept edge has exactly one tag and `M.keysSet _depsProv
  == _deps` at every `ADDef` site. Emitted as `definitionEdgesProvenance`.

- **Don't count authored vs. synthesised clauses via `clauseLHSRange`.**
  Some pass between type-checking and the backend hook runs `KillRange` on
  `Clause`, so every clause we receive has `noRange` — even clearly
  authored multi-clause defs. A `--with-clause-origin` field was
  prototyped and removed (every entry was `(0, total)` — a clause counter,
  not a signal). Use `funCompiled` (`CompiledClauses`) or work upstream of
  the killRange pass instead.

- **`catchError` cannot catch `__IMPOSSIBLE__` (exit 120); the partial
  pass guards with `catchAllTCM`.** Agda's `Impossible` is a GHC
  exception, not a `TCErr`. `catchAllTCM` (TCErr + GHC exceptions;
  re-throws `ExitCode` + async) guards every stage — per definition, per
  module, per interface merge; `preCompile` / `postCompile` add named
  diagnostics + rethrow. Companion: TCM's `catchError` rolls back the whole
  `TCState` on failure, so `partialCompilerMain` must rebuild import state
  from the decoded interfaces via `mergeIfaceState` (signature alone isn't
  enough — missing builtins kill `--with-signatures` reification in
  `infallibleSortKit`); it merges builtins with per-prim rebinds, remote
  metas, pattern synonyms, display forms. The partial pass passes
  `NotMain` to every module's hooks (passing `IsMain` made `entryModule`
  record whichever module ran last). Don't simplify back to `catchError`.
  Locked by `test-keepgoing/` + CI.

- **Regenerate the golden from a COLD run** (`rm -f test/*.agdai` first —
  CI does). A warm-loaded main module skips the `getSignature`
  dead-private recovery and emits a poorer graph (the warm-`.agdai` edge
  loss: `Test.Int-0`-class pattern helpers lose edges/kind/type). The loss
  is MAIN-MODULE-ONLY: `stSignature` holds only the entry module's defs at
  backend time, so imported modules' emission is cache-state independent.

- **`--incremental` fragment invariants.** Fragments must carry the
  module's `ignoredEdgesRef` + `methodProvidersRef` contributions — a
  `Skip`ped module never runs `compileDef`, so without them
  `contractIgnoredEdges` silently loses every edge through its
  with-/where-helpers. The slices must be before/after deltas (`ModuleEnv`
  snapshots), not name-prefix filters: Agda homes module-instantiation
  copies at bare `_.…`/prefixless QNames that no interface name prefixes
  (prefix slicing lost ~12k contracted edges on Jolteon).

- **`--packed-analytical` parity is by construction, and `access` is
  3-valued.** The analytical packed arrays (`kinds`/`lines`/`access`/
  `types`/subterm CSR) must agree node-for-node with expanded (the
  consumer treats them as interchangeable). Parity is guaranteed by
  sharing the per-QName lookups (`mkDefKind`/`mkDefLine`/… over the same
  `defsList`) between `toExpandedGraph` and `buildGraphJson` — don't inline
  them per-form. `access` must stay 3-valued (`encodeDefAccess`:
  `0`=unknown/absent, `1`=public, `2`=private): expanded omits
  `access`/`line`/`type` for QNames with no local `ADDef`, and `0`
  round-trips to that omission; a 2-valued enum breaks the byte-identical
  gate on every external node. Gate: `schema/packed_analytical_check.py`
  (run both sides cold).

- **`--incremental` serialise skip (`SerialiseCache`).** The monolithic
  no-op skip needs BOTH guards: `not anyRecompiled` (per `recompiledRef` —
  guards per-definition content) AND a matching `outputToken` (module set +
  output-affecting options + build identity — guards everything else).
  Dropping either serves stale output, so `outputToken` must list every
  output-affecting option (same discipline as `NFData Options`). The lazy
  per-module skip is content-epoch based (`mdjEpoch`, from the exact
  renderOne inputs without base64) and self-corrects on a global-index
  shift. Serialisation rides Agda's `EmbPrj` (exact `QName`/`NameId`
  round-trip); the byte layer (`Agda.Utils.Serialize`) is 2.9-only — on 2.8
  the flag warns + no-ops. Bump `fragmentFormatVersion` when the payload
  shape changes; `optionsFingerprint` must list every flag that changes
  fragment content. Disabled under `--keep-going`. The warm-rebuild floor
  is Agda's interface load, not serialise — this helps signature-/source-
  heavy output and no-op rebuilds, not the floor.

## State semantics

Every definition in the graph carries one of four states:

- **`D` Defined.** Elaborated normally: a `Function` with clauses,
  a `Datatype`, `Record`, `Constructor`.
- **`P` Postulate.** Body matches `Axiom{}` — user-written `postulate`
  or an Agda primitive. No operational content; type-level promise.
- **`H` Hole.** Definition contains an unsolved meta. Three signals:
  the QName itself starts with `unsolved#meta.` (Agda's
  `openMetasToPostulates` rewrites `?` into a synthetic postulate of
  that name under `--allow-unsolved-metas`), the def *references* such
  a name, or a syntactic walk of `defType`/`theDef` finds an open
  `MetaV` (via `lookupMetaInstantiation` + `isOpenMeta`). The
  synthetic-name path is the one that actually fires in practice — by
  the time the backend runs, Agda has already rewritten user `?`s.
- **`F` Failed.** **Module-level**, not def-level. Synthesised by
  `--keep-going` when a module's type-check raised `TCErr`: marker
  node carrying the module name. Read as "we tried; the module's
  contents are not available" — neither "absent" nor "trustworthy".

Wire encoding: packed JSON → `Int8` byte (0/1/2/3); expanded JSON +
the v2 `graph.json` consumed by HTML → letter `"D"` / `"P"` / `"H"` /
`"F"`.

## v2 graph.json schema

All HTML views consume the v2 schema; `--format=json` emits it
directly. The **expanded** form has a machine-readable JSON Schema at
[`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json)
(draft 2020-12). `required` covers the fields emitted since v2
inception; additive fields (`nodeKeyVersion`, `producer`,
`definitionEdgesProvenance`, `definitionSubterm*`, `externals_summary`,
per-def `line`/`access`/`type`) are optional, and `additionalProperties`
is open, so it validates older and forward-compatible output too. The
`packed` form and `--lazy` layout are not (yet) schematised.

**Schema single-source-of-truth + drift check (do not hand-edit the
committed schema casually).** The expanded wire shape is described once
in `AgdaDeps.Backend.Wire` (field tables + a small `SchemaDoc` ADT).
`agda-deps --emit-schema` regenerates the JSON Schema from it, and CI
(`schema/check_schema.py`) fails if that regenerated schema diverges
*structurally* (ignoring `description`/`$id`/`$schema`/`title`, sorting
`required`/`enum`) from the committed
`schema/graph-v2-expanded.schema.json`. So the committed file is a
frozen **oracle**: to change the wire shape you change `Wire.hs`, the
check fails, and you update the committed schema deliberately in the
same change — no silent schema drift. CI still also runs
`check-jsonschema` of freshly-generated expanded output against the
committed schema (conformance). **Emission goes through the same field
tables:** `buildExpandedJson` builds an `ExpandedGraph` and calls
`encodeExpanded` (= `encodeObject expandedFields`), which emits *only*
fields present in the tables. So a field cannot be emitted without being
in `Wire.hs` (hence in the generated schema), and the generated schema
cannot diverge from the committed oracle without CI failing:
emitted-bytes ≡ `Wire.hs` ≡ committed, by construction. `Wire.hs` is
also the single source of the expanded wire tags (`wireState` /
`wireKind` / `wireAccess`; `GraphJson` no longer carries its own
`stateLetter`/`kindTag`/etc.). The `packed` form and `--lazy` layout are
still hand-rolled in `GraphJson` and not covered. Two further guards:
`Wire.validateExpanded` (run by `buildExpandedJson`, which `error`s on
violation) asserts the cross-array length + edge-endpoint invariants the
schema can't express; and a committed golden
(`test/golden/expanded.golden.json` + `schema/golden_check.py`, CI-diffed)
catches *content* regressions (states/kinds/edges/…) after normalising
out build/layout/path-volatile fields. Three conventions for downstream
consumers:

- **Schema version.** Every payload starts with `"v": 2`. Expanded
  form additionally emits `"schemaVersion": 2` and `"mode": "expanded"`.
  Refuse a `v` you don't recognise — silent decoding of a future v3
  produces wrong-looking snapshots.

- **Build provenance.** Both forms also emit `"producer"` (the
  `BuildInfo.buildFingerprint` of the emitting `agda-deps`) and
  `"nodeKeyVersion"` (the `AgdaDeps.Deps.nodeKeyVersion` node-key
  convention version). Both additive/optional: absent `nodeKeyVersion`
  parses as `1` (pre-E1 collapsed-helper format). The schema *version*
  (`v`/`schemaVersion`) is for wire-shape compatibility; `nodeKeyVersion`
  is orthogonal — it tracks the *node naming* convention so a consumer
  can spot a stale-format cache whose wire shape is still v2 (the E1 fix
  changed helper names without changing the shape) and rebuild rather
  than serve results keyed by an older convention.

- **JSON mode** (`--json-mode=packed|expanded`).
  - *packed* — adjacency in CSR form; per-def state in base64 typed
    arrays. Best for 100k+ node projects. See
    `AgdaDeps.Backend.GraphJson.buildGraphJson`.
  - *expanded* — arrays of records keyed by qname / module name. No
    base64. Carries explicit `schemaVersion` / `mode`. Includes
    `kind` per definition and the `reexports[]` array. Round 4
    added an optional `definitionEdgesProvenance :: [Provenance]`
    array parallel to `definitionEdges`, where `Provenance` is
    `signature | body | module-local | with | unknown` (the
    `module-local` value was `where` before nodeKeyVersion 3 — see the
    Edge-provenance gotcha); older JSON without it parses cleanly
    (consumer treats the absence as "every edge is `unknown`"). `agda-deps` now emits this array on every
    expanded-mode output, so consumers can rely on its presence in
    fresh JSON; only legacy fixtures still hit the absence path.
    See `buildExpandedJson` for the emission, `AgdaDeps.Deps.tagOne`
    for the per-edge classification. Under `--with-signatures` each
    definition object additionally carries an optional `"type"` string
    (the reified type, not normalised, Agda's default printing — no
    `--show-implicit`; rendered in `AgdaDeps.Deps.computeDefAD` via
    `prettyTCM`, emitted by `buildExpandedJson`). Absent without the
    flag, so default output is byte-identical.

- **Lazy ingest path** (`--lazy`). Wire format split across files:
  - `graph.json` — module-level skeleton:
    - `modules :: [String]`
    - `moduleEdges :: [[Int, Int]]` — pairs of indices into `modules`.
    - `moduleFiles :: Map String FilePath` — name →
      `modules/<Module>.json`. **This is the manifest** — walk
      it; never derive a URL from a module name directly (the Haskell
      side falls back to `detail-<hash>.json` for non-safe names).
    - `bundleFiles :: Map String FilePath` — name →
      `snippets/<Module>.json`, present only when `--with-source` was
      set.
  - `modules/<Module>.json` — that module's defs (`names`,
    `states`, `x`, `y`) plus outgoing leaf edges with
    `targetModule` annotations. (The on-disk file is `<Module>.json`,
    *not* `<Module>.detail.json`; the manifest above carries the real
    name either way. `graph.json` also emits the richer module-level
    fields the views consume — `moduleStates`, `moduleDepth`,
    `modulePodLayout`, `fileTree`/`moduleTree`, `transitiveModuleEdges`,
    CSR `moduleToFile`/`fileToModules` — none of which the lazy schema
    is (yet) formally documented for.)

  Lazy output requires HTTP serving (browsers block `fetch()` on
  `file://`).

## Reference

- Inspiration / prior art for the HTML view:
  <https://unimath.github.io/agda-unimath/VISUALIZATION.html>.
