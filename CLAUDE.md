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
  real definition vs. compiler-generated noise. Changes to the *set*
  of nodes belong here. Anything that only changes the *rendering*
  (colour, snippet, label) lives in `computeDefAD` / `postCompileAD`,
  not `ignoreDef`.

- **`ignoreDef` filters every `defCopy`** at the top level
  (regardless of `theDef`'s shape). Module-instantiation copies are
  produced for `Record` / `Datatype` / `Constructor` / `Projection`
  too — not just `Function` (`funInline`). Without the top-level
  `defCopy` short-circuit, ghost defs surface in the importing module.

- **`ignoreDef`'s `funInline` drop is deliberate — don't remove it
  (round-8 don't-revert).** It looks redundant with the `defCopy` guard
  (the old "from instantiated modules" comment was wrong: module copies
  are `defCopy`, caught earlier). Its real effect is dropping user
  `{-# INLINE #-}` functions, and that is *correct*: Agda inlines every
  call to an INLINE function into the caller's body during
  type-checking, upstream of `compileDefAD`, so by the time the Backend
  sees the elaborated `Defn` the INLINE function has **zero incoming
  edges** (callers reference its body, e.g. `_+_`, not the function).
  Keeping it as a node therefore adds a permanent zero-caller orphan
  that a downstream dead-code pass flags as a false `dead`. The lost
  call edges are *not* a contraction artefact and are unrecoverable from
  post-elaboration syntax — verified by `test/InlineGap.agda`
  (`twice` + `useInline`/`aliasTwice`): dropping the pragma makes all
  three `⇝ twice` edges reappear; disabling the `funInline` rule keeps
  `twice` as a node but the callers still point at `_+_`. Producer-side
  recovery would need pre-inline abstract syntax; the consumer-side
  source scan is the right fix. See [Backlog.md](Backlog.md) (#3).

- **Scope captured per-module, not per-definition** —
  `getCurrentScope` runs in `moduleSetup`, not in each
  `compileDefAD`. Deliberate fix in commit `929fa83`; do not revert.

- **`ignoreDependency` filtering moved from `computeDefAD` (per-def)
  to `contractIgnoredEdges` (once, on the contracted set).** Order
  matters: raw hidden refs need to survive long enough for the
  contraction pass to expand them. Reverting this loses edges
  through `with-`helpers / inliner copies.

- **`hashQName = hashString . nodeKey`, and `nodeKey` is
  `liftAnonSegments . prettyShow` *plus a `@<binding-line>` suffix for
  `._.` helpers* — not bare `prettyShow`, and *never* derived `show`.**
  Derived `Show` includes `NameId` metadata that diverges between QNames
  sourced from `iSignature` vs `stSignature`, so it can't key nodes.
  `prettyShow` alone fixes that but over-collapses: every same-named
  `where`/anonymous-module helper in a module renders identically as
  `Mod._.simpleName`, so they merged onto one node and the rest's edges
  vanished (battle-test E1). `nodeKey` keeps the `prettyShow` stability
  for top-level names and disambiguates `._.` helpers by their
  `nameBindingSite` line — the one per-helper coordinate that *is* stable
  across signature sources. **It also lifts anonymous-module segments
  (the `_` that Agda renders for both `where` blocks and `module _ (…)
  where` sections) out of the name via `AgdaDeps.Util.liftAnonSegments`:
  `Mod._.helper@15` ↦ `Mod.helper@15`, `Mod._._.deep` ↦ `Mod.deep`
  (nodeKeyVersion 3).** Agda desugars *both* `where` and parameterised
  sections into anonymous `Mod._` sub-modules and lifts the enclosing
  vars into each def's `defType`, so the dependency edges are already
  correct — the blind spot was *naming/attribution* only. Don't try to
  distinguish `where` from section here: post-scope-check they are
  identical (`h` in a `where`-block and `amHelper` in a section both home
  to `Mod._`); only `liftAnonSegments` re-homes them, and the matching
  `moduleKey` (= `liftAnonSegments . prettyShow . qnameModule`) is the
  single source of *module attribution* (kills phantom `Mod._` module
  nodes + their false `Mod ⇄ Mod._` cycles). **Every site that derives a
  module string from a QName must route through `moduleKey`** (externals
  classification, `--exclude` matching, module DAG, snippet/bundle
  manifests, DOT clusters) or set/index/membership drift apart. This is
  the single source of truth for node identity: the wire `"name"`
  (expanded + packed) and edge endpoints derive from `nodeKey`, and the
  expanded-edge filter resolves by the canonical string, **not** `QName`
  `Ord` (which distinguishes same-`nodeKey` helpers and would re-drop
  their edges). Don't revert to bare `prettyShow`; the regressions live
  in `test/Collision.agda` (E1, same-named `where` helpers) and
  `test/AnonSection.agda` (parameterised + nested sections), both
  imported by `test/Test.agda`.

- **`nodeKeyVersion` tracks the node-naming convention.**
  `AgdaDeps.Deps.nodeKeyVersion` is stamped into `graph.json` so a
  downstream consumer of the wire format can detect a stale-format
  cached graph (same wire shape, different node names) and rebuild
  rather than silently serving results keyed by an older convention.
  Whenever `nodeKey` changes shape, bump it. Currently **3** (1 = bare
  `prettyShow`; 2 = `@<line>` disambiguator on `._.` helpers; 3 =
  anonymous-module segments lifted into the named ancestor). The sibling
  consumer repo `agda-graph-explorer` reads this same constant — a bump
  is a cross-repo coordination point.

- **`BuildInfo` is split across two modules for the TH stage
  restriction.** The git-revision splice generator lives in
  `BuildInfoTH` (its own module) because GHC forbids a top-level splice
  from using a generator defined in the *same* module. `BuildInfo` does
  the `$(gitRevisionE)` splice + the CPP `__DATE__`/`__TIME__` + version
  assembly. Both are listed in `other-modules` of the `agda-deps`
  stanza (with `Paths_agda_deps` + `template-haskell`) — there is no
  library to share them through (`agda-deps` is aeson-free). The
  fingerprint is recaptured whenever `BuildInfo` recompiles (always on a
  GHC bump). **It does *not* move across an uncommitted rebuild that only
  touches other modules** — the `built …` date freezes (CPP captured it
  last time `BuildInfo` compiled) and the git SHA + `+` marker don't
  change without a commit. This bit battle-test round 5 (E5.1): two
  byte-different binaries from the same dirty commit stamped an identical
  fingerprint. The reliable discriminator is therefore **not** the
  fingerprint but the running binary's *mtime*.

- **Output routing.** DOT / JSON → `<outDir>/deps.dot|.json`, falling
  back to stdout when `optOutDir` is `Nothing`. HTML → `<outDir>/deps.html`
  and errors out if `optOutDir` is unset. `postCompileAD` creates
  `optOutDir` via `createDirectoryIfMissing True`.

- **Agda 2.8 / 2.9 version coupling.** `Agda >= 2.8 && < 3` in
  `agda-deps.cabal`; the default `cabal.project` pins the
  `source-repository-package` to a specific upstream 2.9 commit
  (2.9.0 isn't on Hackage yet). `cabal.project.agda28` (GHC 9.6 +
  Hackage `Agda ==2.8.0`) builds the 2.8 variant:
  `cabal build --project-file=cabal.project.agda28 --builddir=dist-agda28 agda-deps`.
  Which Agda you get is decided entirely by the cabal solver — no
  flag. The 2.8/2.9 internal-API deltas are bridged with CPP keyed on
  `MIN_VERSION_Agda(2,9,0)` in five modules:
  - `Util.hs` — `funWith` is `Maybe QName` (2.8) vs `IsWithFunction QName` (2.9).
  - `Help.hs` — `usageInfo` gained a leading column-width arg in 2.9.
  - `Main.hs` — 2.8 has no `runAgdaArgs`; shimmed via `withArgs` + `runAgda'`.
  - `Backend.hs` — `anameName` lives in `Scope.Base` (2.8) vs `Abstract.Name` (2.9).
  - `ModuleExplorer.hs` — `stCurrentModule` lazy `Maybe (_,_)` (2.8) vs strict
    `:!:` (2.9); `setTCLens' stBackends` (2.8) vs `setSession lensBackends` (2.9).
  **CPP gotcha:** the five CPP-enabled modules must not use backslash
  string gaps (`"…\`↵`\…"`) — the C preprocessor collapses
  `\`-newline. Use `++` concatenation instead (see the `--with-source`
  notice in `Backend.hs`). The backend also uses several `pattern`
  synonyms re-exported from `Agda.TypeChecking.Monad` (`Function`,
  `Primitive`, `Axiom`, `DataOrRecSig`, `PrimitiveSort`); meta /
  hole detection pulls in `Agda.TypeChecking.Monad.MetaVars`;
  the source view depends on
  `Agda.Interaction.Highlighting.HTML.Base`. Note: Agda 2.9's
  `funProjection` is `Either ProjectionLikenessMissing Projection`,
  not `Maybe Projection` — projection branch matches
  `Right{projProper = Just _}`. Keep version-coupled imports grouped.
  Both builds produce byte-identical graphs (modulo the build-specific
  `producer` fingerprint).

- **`Main.hs` argv pre-processing**: canonicalize path-bearing flags
  (`-o`, `-i`, `--include-path`, `--out-dir`, `.agda`/`.lagda*`
  positionals) to absolute paths, then `setCurrentDirectory` to the
  nearest ancestor of an `-i` path or source file that contains a
  `*.agda-lib`. Skipped if `--no-libraries`, `--library`, `-l`, or
  `--library-file` is passed. This is what lets users run from
  outside the project source directory without losing library deps,
  and what makes `classifyExternalModules`'s cwd-prefix check work.

- **Adding flags.** Extend `Options` + `commandLineFlags`, **and**
  the corresponding `Config.hs`'s `applyConfig` so the new flag is
  reachable from YAML in kebab-case (`--no-externals` ↔
  `no-externals`). The YAML layer is intentionally a thin mirror of
  the CLI surface — don't introduce a second configuration
  mechanism. `NFData Options` deeply forces every field; keep the
  instance in sync. Merge order: defaults → config → CLI.

- **Adding a view.** Extend `View`; add `viewSlug` branch + `viewOpt`
  case; add the template path to `extra-source-files` in
  `agda-deps.cabal`; add the `templateRawFor` line. Placeholder
  contract (`__DATA_LOADING_PRELUDE__`, `__COLOR_DEFINED__`, …) is
  documented in the existing templates — copy from
  `sigma.html.tmpl` as the minimal starting point. **Do not add a
  new `--<slug>` shortcut flag** — the previous fourteen were
  removed 2026-05-29 (Changelog), after a one-release deprecation
  window. `--view=NAME` and YAML `view: NAME` are the only surface.

- **Config layer (YAML).** `agda-deps` reads a YAML config via
  `AgdaDeps.Config` (`.agda-deps.yml`). Discovery, in order:
  `--config=PATH` > `$AGDA_DEPS_CONFIG` > `./.agda-deps.yml` (or
  `.yaml`) > walk up from `cwd` to the first ancestor containing a
  `*.agda-lib` and pick the dotfile there. Merge order: **defaults →
  config → CLI** — never the other way. Top-level YAML keys are
  kebab-case mirrors of the CLI flag names. Bad type / unknown key
  produces an error naming file + key and exits 1. A stderr breadcrumb
  (`agda-deps: applied config from /abs/path/…`) fires when a config
  applies; suppressed by `--quiet`.

- **`--theme` is a colour preset, not a configuration system.** The
  four state colours (`color-defined` / `color-postulate` /
  `color-hole` / `color-failed`) live in `Options`; `--theme` /
  YAML `theme:` resolves to a four-tuple and writes those four
  fields. Explicit `--color-*` CLI flags still win because they
  layer on top of the theme during CLI parsing. Adding a new theme
  is a tuple in `AgdaDeps.Config`; don't grow `View` or `Options`
  for it.

- **Auto-format from `-o`.** When `--format` is **not** explicitly
  set and `optOutDir` ends in `.html` / `.json` / `.dot`, the
  format is inferred from the extension. Explicit `--format=…`
  always wins. Directory paths and extension-less filenames keep
  the default (`dot`). The inference lives in `Main.hs`'s argv
  pre-processing pass; don't duplicate it inside the backend.

- **Scaling.** Prefer strict `Map` / `IntMap` / `IntSet` / `Set`
  folds; avoid `(++)` queue patterns; use `Data.Sequence` for BFS
  queues; `BangPatterns` on `foldl'` accumulators. See
  [Changelog.md](Changelog.md) G10 for the audit log.

- **`agda-deps` is single-threaded on purpose.** Agda's `TCM` and
  `IORef`-backed type-checking state aren't thread-safe, and the
  `Backend'` hooks (`compileDefAD`, `postModuleAD`, `moduleSetup`) are
  called serially by the upstream compiler. Don't add `parMap` /
  `forkIO` / `Async` to anything under `src/AgdaDeps/`. Post-Agda IO
  inside `postCompileAD` *would* be safe to parallelise; see
  [Backlog.md](Backlog.md) for the deferred entry.

- **Edge provenance (producer side).** `agda-deps`'s `computeDefAD`
  walks `defType` and `theDef` separately (`AgdaDeps.Deps.tagOne`):
  names in `defType` become `Signature`; names in `theDef` become
  `Body`, refined to `With` when the parent's `funWith` points at the
  target and `ModuleLocal` (wire tag `module-local`) when the qname's
  `prettyShow` contains the `._.` anonymous-module marker. **`module-local`
  is a property of the *target*, not the (src, dst) pair**: it says the
  target is an anonymous-module-local helper (a `where`-block helper *or*
  a parameterised-section member — Agda represents both identically, see
  the `nodeKey` gotcha), and does *not* claim the target is owned by this
  specific source. It was named `where` before nodeKeyVersion 3; that was
  a lie for section siblings/consumers, since the marker fires for any
  `._.` target regardless of ownership, and post-scope-check ownership is
  unrecoverable. Precedence on collision is
  `Signature > With > ModuleLocal > Body > Unknown`. The side-channel
  `IgnoredEdgeMap` carries provenance through `contractIgnoredEdges`
  — contracted edges inherit the **source** side's provenance
  toward the hidden helper (not the helper's internal tag);
  `addInstanceMethodEdges` adds inferred-method edges as `Unknown`
  with a left-biased `M.union` so any pre-existing tag survives.
  Current invariant: every kept edge has exactly one provenance tag
  and `M.keysSet _depsProv == _deps` holds at every `ADDef`
  construction / rewrite site. This is emitted as
  `definitionEdgesProvenance` in expanded JSON.

- **`clauseLHSRange` is stripped before the backend hook fires
  (round-7 don't-repeat).** Tempting to count authored vs.
  elaborator-inserted clauses per def by checking whether each
  `Clause`'s `clauseLHSRange` equals `noRange` — Agda's source
  shows `Rules/Def.hs:807` sets it via `getRange i` for authored
  clauses and `Coverage.hs:188` / `Coinduction.hs:140` /
  `Record/Cubical.hs` use `noRange` for synthesised ones. **In
  practice every clause we receive in `compileDefAD` has
  `noRange`**, including clearly-authored multi-clause defs like
  `sum [] = …; sum (x ∷ xs) = …`. Some pass between
  type-checking and the backend hook invokes the `KillRange`
  instance on `Clause`; haven't tracked down which. A
  `--with-clause-origin` field was prototyped and removed —
  every entry was `(0, totalClauses)`, which is just a clause
  counter dressed as a signal. If you want authored-vs-synthesised,
  look at `funCompiled :: CompiledClauses` (the case-tree
  representation) or work upstream of the killRange pass, NOT at
  `clauseLHSRange`.

- **`catchError` cannot catch `__IMPOSSIBLE__` (exit 120) — the
  partial pass guards with `catchAllTCM`.** Agda's `Impossible` is a
  GHC exception, not a `TCErr`; before 2026-06-12 every guard in
  `ModuleExplorer` was `catchError`-only, so one internal error killed
  the whole `--keep-going` pass with a bare exit 120 and no output.
  `catchAllTCM` (built on the `TCM`/`unTCM` newtype, present in both
  2.8 and 2.9; re-throws `ExitCode` + async) now guards every stage:
  per definition, per module, per interface merge; `preCompile` /
  `postCompile` get named diagnostics + rethrow. Don't "simplify"
  these back to `catchError`. Companion fix: TCM's `catchError`
  instance ROLLS BACK the whole TCState on a check failure, so
  `partialCompilerMain` must rebuild the import state from the decoded
  interfaces via `mergeIfaceState` — signature alone is not enough
  (missing builtins kill `--with-signatures` reification in
  `infallibleSortKit`); it merges builtins (with per-prim rebinds),
  remote metas, pattern synonyms, and display forms, mirroring Agda's
  non-exported `mergeInterface`. Also: the partial pass passes
  `NotMain` to every module's hooks — passing the global `IsMain`
  made `entryModule` record whichever module was processed last.
  Locked by `test-keepgoing/` + the CI step.

- **The golden must be regenerated from a COLD run** (`rm -f
  test/*.agdai` first — CI does this before the runs that feed the
  golden check). A warm-loaded main module skips the `getSignature`
  dead-private recovery and emits a slightly poorer graph (the
  "warm-`.agdai` edge loss" — `Test.Int-0`-class pattern helpers lose
  edges/kind/type). The loss is MAIN-MODULE-ONLY: `stSignature` holds
  only the entry module's defs at backend time, so imported modules'
  emission is a pure function of their pruned interface, cache-state
  independent. The pre-2026-06-12 golden was warm-derived and CI
  only stayed green because its expanded run was the fifth (warm)
  corpus invocation.

- **`--incremental` fragment invariants.** Fragments must carry the
  module's `ignoredEdgesRef` + `methodProvidersRef` contributions — a
  `Skip`ped module never runs `compileDef`, so without them
  `contractIgnoredEdges` silently loses every edge through that
  module's with-/where-helpers. **The slices must be before/after
  deltas (snapshots in `ModuleEnv`), not name-prefix filters**: Agda
  homes module-instantiation copies from anonymous blocks
  (`module _ ⦃ asm ⦄ where open Assumptions asm public`) at bare
  `_.…`/prefixless QNames that no interface's module name prefixes —
  prefix slicing lost 21 such helpers (≈12k contracted edges) on
  Jolteon while the small corpus stayed green, so don't "simplify"
  the delta back to a filter.

- **`--packed-analytical` parity is by construction, and `access` is
  3-valued.** The analytical packed arrays (`kinds`/`lines`/`access`/
  `types`/subterm CSR in `defsObjectJson`) must agree node-for-node with
  the expanded form, because the consumer treats them as interchangeable.
  That parity is guaranteed by sharing the per-QName lookups
  (`mkDefKind`/`mkDefLine`/`mkDefAccess`/`mkDefSig`/`mkDefHashes`/
  `mkDefDepths`) between `toExpandedGraph` and `buildGraphJson` over the
  same `defsList` — **don't inline them back per-form** or the defaults
  for dep-only QNames will drift. `access` MUST stay 3-valued
  (`encodeDefAccess`: `0`=unknown/absent, `1`=public, `2`=private):
  expanded *omits* `access` (and `line`, and `type`) for QNames with no
  local `ADDef`, so the unknown value is what round-trips to that
  omission; a 2-valued enum silently breaks the byte-identical gate on
  every external node. The gate is `schema/packed_analytical_check.py`
  (run both sides cold — a warm `.agdai` degrades only one side's main
  module and yields a spurious mismatch).

- **`--incremental` serialise skip (`SerialiseCache`) — the monolithic
  no-op skip needs BOTH guards, the lazy skip needs the content epoch.**
  Monolithic `deps.json`/`deps.html` is skipped only when
  `not anyRecompiled` (per `recompiledRef`, set in `moduleSetup`'s
  Recompile branch — this guards per-definition *content*) AND the
  `outputToken` matches (module set + output-affecting options + build
  identity — this guards everything else). Dropping either guard serves
  stale output: the token alone misses a recompiled body (same module
  set/options), and `anyRecompiled` alone misses a toggled rendering
  option like `--no-externals` (not in the fragment fingerprint, doesn't
  cause a recompile). **`outputToken` must list every output-affecting
  option** (same discipline as `NFData Options`) — a missing one means a
  stale skip. The lazy per-module skip is content-epoch based
  (`mdjEpoch`, computed from the *exact* renderOne inputs without base64,
  so the content thunk isn't forced for skipped files); it self-corrects
  on a global-index shift because `outEdges` (hence the epoch) change.
  The measured warm-rebuild floor is Agda's interface load, NOT
  serialise — so this helps signature-/source-heavy output and no-op
  rebuilds, not the floor. The main module is cached only from a
  fresh check (see the gotcha above); imported modules
  unconditionally. Serialisation rides Agda's `EmbPrj` so `QName`s
  round-trip with exact `NameId`s (required: `getConstInfo` and the
  `Map QName` joins key on `NameId`); the byte layer
  (`Agda.Utils.Serialize`) is only exported by Agda ≥ 2.9 — on 2.8
  `fragmentCacheSupported = False` and the flag warns + no-ops. Bump
  `fragmentFormatVersion` whenever the wire payload shape changes;
  the option fingerprint must list every flag that changes fragment
  *content* (`optionsFingerprint`). Disabled under `--keep-going`.

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
