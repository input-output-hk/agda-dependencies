# CLAUDE.md

Guidance for Claude Code in this repository.

## Project overview

`agda-deps` is an Agda compiler backend (not a standalone tool) that emits a
graph of lemma / definition dependencies. It registers as a `Backend` via
`Agda.Main.runAgda`, so it runs inside Agda's type-checking pipeline and is
driven through the Agda CLI.

Outputs:

- **DOT** (Graphviz)
- **HTML** — self-contained or `--lazy` split-files, in one of several *views*
  (`module-dag-pods` default, `cytoscape`, `sigma`, `big-module-dag-pods`,
  dashboards, hierarchical, …).
- **JSON** — v2 `graph.json`, `packed` or `expanded`.

Each node is coloured by state — `D`efined / `P`ostulate / `H`ole / `F`ailed
(see [State semantics](#state-semantics)). The emitted `graph.json` is a stable
wire artifact; its [v2 schema](#v2-graphjson-schema) is the contract.

End-user docs: [README.md](README.md). History: [Changelog.md](Changelog.md).
Planned / deferred: [TODO.md](TODO.md), [Backlog.md](Backlog.md).

## Build / run

```
cabal build
cabal run agda-deps -- -i test/ -o test/ test/Test.agda
```

`--` separates cabal flags from backend arguments. After `--`, flags are Agda CLI
flags (`-i` include path; trailing positional is the module). Backend flags live
in `commandLineFlags` (`src/AgdaDeps/Backend.hs`) and [README.md](README.md).

Stable on-`PATH` binary: `cabal install exe:agda-deps --overwrite-policy=always`.
`agda-deps --version` prints the build fingerprint (version + git rev + date +
GHC) — the same string stamped into `graph.json` as `"producer"`.

No test suite or lint config. Exercise the backend against `test/` (entry
`test/Test.agda`). CI (`.github/workflows/ci.yml`) builds and runs `dot` / `html`
/ `html --lazy` / `json` over this corpus.

Two side-channels skip parts of the pipeline:

- `--keep-going` — catches type-check errors and proceeds with whatever loaded
  (`ModuleExplorer`; failing module tagged `F`).
- `--skip-agda` — skips Agda entirely; renders a module-level graph from the
  source scan (`SkipAgda` + `Precompute`).

## Module map

```
src/Main.hs               argv pre-processing, .agda-lib discovery, dispatch to
                          runSkipAgda / runAgdaArgsKeepGoing / runAgdaArgs, and
                          the `doctor` subcommand intercept (first, so
                          `doctor --help` is the subcommand's own usage).
src/BuildInfo.hs          Compile-time build identity (version + git rev + date +
                          GHC); surfaced in --version and graph.json "producer".
src/BuildInfoTH.hs        TH helper behind BuildInfo (split out for the stage
                          restriction): captures the git revision at build time.

src/AgdaDeps/
  Backend.hs              Backend' record + hooks (moduleSetup, compileDefAD,
                          postModuleAD, postCompileAD); CLI flag list;
                          post-compile dispatcher; dropExternalDefs,
                          collectReExports, classifyExternalModules.
  Driver.hs               Thin shim exposing runAgdaArgsKeepGoing.
  ModuleExplorer.hs       --keep-going glue: catches check failures (catchAllTCM)
                          and re-drives the hooks over every decoded interface
                          (rebuilding import state via mergeIfaceState) so
                          postCompile gets def-level data for every module.
  FragmentCache.hs        --incremental per-module fragment cache (Data.Binary
                          ADDefs + side-channel slices), keyed on iFullHash +
                          option fingerprint + nodeKeyVersion. 2.8 and 2.9
                          (identity is the serialisable NodeRef, not a QName).
                          Also gcFragments.
  SerialiseCache.hs       --incremental serialise: a manifest of content epochs
                          letting a rebuild skip re-emitting unchanged output.
  LibResolve.hs           --resolve-deps: parses .agda-lib + Agda's libraries
                          registry, walks the depend: closure, returns the
                          '--no-libraries -i <dir> …' argv (wired in Main.hs).
  SkipAgda.hs             --skip-agda entry point.
  Precompute.hs           Line-scan for module / import declarations.
  Help.hs                 --help / --version intercepts.
  Logging.hs              quietRef + info.
  Options.hs              Options record, defaultOptions, parsers, View, JsonMode.
  Config.hs               YAML config loader (.agda-deps.yml) + discovery
                          (findConfigPath carries the ConfigOrigin) +
                          applyConfig + theme presets.
  Doctor.hs               `agda-deps doctor`: validates the resolved config —
                          unknown keys, value type/enum/domain, and coherence
                          between keys. Exit 1 on error (--strict: on warning).
  Deps.hs                 ADDef, compileDefAD, classifyDef, ignoreDef,
                          ignoredEdgesRef, contractIgnoredEdges.
  Layout.hs               (x, y) positions per definition.
  Csr.hs                  CSR adjacency + base64 serialisation.
  Source.hs               --with-source machinery.
  TermCanon.hs            --with-term-hashes: canonicalises each elaborated
                          subterm to a Word64.
  Util.hs                 isWithFun, jsString + JSON encoders, dedupOrd,
                          hex-colour parsing, argv inspection.
  Backend/
    Wire.hs               Single source of truth for the v2 *expanded* wire shape
                          (field tables + SchemaDoc). Generates the JSON Schema
                          (--emit-schema) and encodes the output (encodeExpanded).
    GraphJson.hs          v2 graph.json emitter. Packed + --lazy hand-rolled here;
                          expanded's buildExpandedJson defers encoding to Wire, so
                          its field set IS Wire's by construction.
    Html.hs               renderHtml / renderLazyHtml + renderHtmlFromInput.
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
compileDefAD      per Definition: filter via ignoreDef, walk defType + theDef for
                  dep QNames, classifyDef tags state, classifyKind tags kind.
                  Records ignored defs' raw out-edges in ignoredEdgesRef.
postModuleAD      diffs getSignature (pre-prune) vs visited QNames to recover
                  dead-end private defs eliminateDeadCode pruned; feeds them
                  through compileDefAD. Captures the entry module on IsMain.
postCompileAD     aggregate ADDefs; contractIgnoredEdges expands hidden refs into
                  transitive non-hidden targets; dispatch on optFormat to
                  renderDot / renderHtml{,Lazy} / renderJson.
```

## Hard-won gotchas (don't revert)

- **`ignoreDef` is the single source of truth** for real definition vs
  compiler-generated noise. Node-set changes go here; rendering-only changes go in
  `computeDefAD` / `postCompileAD`.

- **`ignoreDef` short-circuits on `defCopy` before inspecting `theDef`.**
  Module-instantiation copies exist for `Record` / `Datatype` / `Constructor` /
  `Projection`, not just `Function`; without the short-circuit, ghost defs surface
  in the importing module.

- **Keep `ignoreDef`'s `funInline` drop.** Agda inlines every `{-# INLINE #-}`
  call during type-checking, so the elaborated `Defn` has zero incoming edges — a
  permanent false-`dead` orphan. Call edges are unrecoverable post-elaboration
  (fixture `test/InlineGap.agda`); the fix is a consumer-side source scan.

- **Scope is captured per-module in `moduleSetup`** (`getCurrentScope`), not
  per-definition. Don't move it.

- **Filter `ignoreDependency` once in `contractIgnoredEdges`** (on the contracted
  set), not per-def: raw hidden refs must survive for the contraction pass to
  expand them, else edges through with-/where-helpers are lost.

- **Node identity is a `NodeRef`, built once at the producer boundary.** `ADDef`
  and both side-channels are keyed by `NodeRef` — a `Data.Binary`-serialisable
  bundle (`nodeKey` string + hash + `moduleKey` + line + file + `prettyShow` + a
  precomputed `ignoreDef` flag), not a live `QName`. `mkRef :: QName -> TCM
  NodeRef` does the conversion (the only `getConstInfo` folds into `nrIgnorable`,
  so `contractIgnoredEdges` needs no TCM). The `...OfQ` helpers (`nodeKeyOfQ` /
  `moduleKeyOfQ`) are the QName-level logic, used only by `mkRef` and producer
  sites that see live interface QNames (dead-private recovery, `collectReExports`).
  This is why the fragment cache is plain `Data.Binary` (no `EmbPrj`/CPP, 2.8-safe).

- **Node identity string is `nodeKey`** (`hashQName = hashString . nodeKey`); the
  wire `"name"` and all edge endpoints derive from it, and the expanded-edge filter
  resolves by the canonical string, not `NodeRef`/`QName` `Ord`. `nodeKey`
  disambiguates `._.` helpers with an `@<line>` suffix and lifts anonymous-module
  segments (`Mod._.helper@15` ↦ `Mod.helper@15`) via `Util.liftAnonSegments`;
  post-scope-check `where` and `module _ (…) where` are identical — don't try to
  tell them apart. Every QName→module-string site routes through `moduleKey`
  (`liftAnonSegments . prettyShow . qnameModule`) — externals, `--exclude`, module
  DAG, manifests, DOT clusters — else phantom `Mod._` nodes and false cycles
  appear. Regressions: `test/Collision.agda`, `test/AnonSection.agda`.

- **`nodeKeyVersion` tracks the node-naming convention** and is stamped into
  `graph.json` (currently **3**). Bump it whenever `nodeKey` changes shape. The
  consumer repo `agda-graph-explorer` reads the same constant — a bump is a
  cross-repo coordination point.

- **`BuildInfo` is split for the TH stage restriction:** the git-rev splice
  generator lives in `BuildInfoTH` (GHC forbids a splice using a generator from
  its own module). The `built` date freezes across an uncommitted rebuild that
  doesn't recompile `BuildInfo`, so the reliable discriminator between two dirty
  builds is the binary's *mtime*.

- **Output routing.** DOT / JSON → `<outDir>/deps.dot|.json`, else stdout. HTML →
  `<outDir>/deps.html`, erroring if `optOutDir` is unset. `postCompileAD` creates
  `optOutDir`.

- **Agda 2.8 / 2.9 coupling.** The solver picks the version (no flag); both are
  gated in CI against the same golden and produce byte-identical graphs (modulo
  `producer`). API deltas are bridged with CPP on `MIN_VERSION_Agda(2,9,0)` in
  five modules:
  - `Util.hs` — `funWith` is `Maybe QName` (2.8) vs `IsWithFunction QName` (2.9).
  - `Help.hs` — `usageInfo` gained a leading column-width arg in 2.9.
  - `Main.hs` — 2.8 has no `runAgdaArgs`; shimmed via `withArgs` + `runAgda'`.
  - `Backend.hs` — `anameName` in `Scope.Base` (2.8) vs `Abstract.Name` (2.9).
  - `ModuleExplorer.hs` — `stCurrentModule` lazy `Maybe` (2.8) vs strict `:!:`
    (2.9); `setTCLens' stBackends` (2.8) vs `setSession lensBackends` (2.9).

  In CPP modules, don't use backslash string gaps (cpp collapses them) — use `++`.
  Agda 2.9's `funProjection` is `Either ProjectionLikenessMissing Projection` —
  match `Right{projProper = Just _}`.

- **`Main.hs` argv pre-processing** canonicalizes path-bearing flags (`-o`, `-i`,
  `--include-path`, `--out-dir`, `.agda`/`.lagda*` positionals) to absolute paths,
  then `setCurrentDirectory` to the nearest ancestor with a `*.agda-lib`. Skipped
  under `--no-libraries` / `--library` / `-l` / `--library-file`. Lets users run
  from outside the source dir, and makes `classifyExternalModules`'s cwd-prefix
  check work.

- **Adding a flag.** Extend `Options` + `commandLineFlags` **and** `Config.hs`'s
  `applyConfig` + `FromJSON Config` (kebab-case YAML mirror) **and** `NFData
  Options` **and** `Config.showDefaultsYaml` (the `--show-defaults` sample)
  **and** `Doctor.knownFields` (the `agda-deps doctor` key table — plus a
  coherence rule in `checkCoherence` if the flag needs another one to do
  anything). `FromJSON Config` is the source of truth; both mirrors are
  diff-checked against it in CI by `schema/show_defaults_check.py`. Merge
  order: defaults → config → CLI. Don't add a second config mechanism.

- **Enum settings have one slug table.** `allViews` / `allFormats` /
  `allJsonModes` (`Options.hs`) and `allThemes` (`Config.hs`), read through
  `parseSlug`, are what the CLI parser, the `FromJSON` instance, the
  "Expected one of: …" message, and `doctor` all resolve against. Adding a
  value means extending the table, not four case arms.

- **Adding a view.** Extend `View`; add `viewSlug` + `viewOpt` cases; add the
  template to `extra-source-files` in `agda-deps.cabal`; add the `templateRawFor`
  line. The surface is `--view=NAME` / YAML `view: NAME` only.

- **`--theme` is a colour preset** resolving to the four state colours; explicit
  `--color-*` flags win. Adding a theme is a tuple in `Config.hs` — don't grow
  `View` / `Options`.

- **Auto-format from `-o`.** With no `--format`, a `.html`/`.json`/`.dot`
  `optOutDir` infers the format (explicit `--format` wins; directories keep the
  default `dot`). Inference lives in `Main.hs` — don't duplicate it in the backend.

- **Scaling.** Prefer strict `Map` / `IntMap` / `IntSet` / `Set` folds; avoid
  `(++)` queues (use `Data.Sequence` for BFS); `BangPatterns` on `foldl'`
  accumulators.

- **Single-threaded on purpose.** Agda's `TCM` and its `IORef` state aren't
  thread-safe and the `Backend'` hooks run serially. No `parMap` / `forkIO` /
  `Async` under `src/AgdaDeps/`.

- **Edge provenance (producer side).** `computeDefAD` (`Deps.tagOne`) walks
  `defType` and `theDef` separately: `defType` names → `Signature`; `theDef` names
  → `Body`, refined to `With` when the parent's `funWith` points at the target and
  `ModuleLocal` (wire `module-local`) when the qname's `prettyShow` contains
  `._.`. `module-local` is a property of the *target*. Precedence: `Signature >
  With > ModuleLocal > Body > Unknown`. Contracted edges inherit the source side's
  provenance; `addInstanceMethodEdges` adds `Unknown` with a left-biased `M.union`.
  Invariant: every kept edge has one tag and `M.keysSet _depsProv == _deps`.

- **Clauses are all `noRange` post-`KillRange`** — count them with `funCompiled`
  (`CompiledClauses`), not `clauseLHSRange`.

- **The partial pass guards with `catchAllTCM`, not `catchError`.** Agda's
  `__IMPOSSIBLE__` is a GHC exception, not a `TCErr`, so `catchError` can't catch
  it. `catchAllTCM` (TCErr + GHC exceptions; re-throws `ExitCode` + async) guards
  every stage. `catchError` also rolls back the whole `TCState`, so
  `partialCompilerMain` rebuilds import state from the decoded interfaces via
  `mergeIfaceState` (signature alone drops builtins, breaking `--with-signatures`
  reification). Pass `NotMain` to every module (`IsMain` makes `entryModule` record
  whichever ran last). Locked by `test-keepgoing/` + CI.

- **Regenerate the golden from a COLD run** (`rm -f test/*.agdai` first — CI does).
  A warm main module skips the `getSignature` dead-private recovery and emits a
  poorer graph. Main-module-only: `stSignature` holds only the entry module's defs
  at backend time, so imported modules are cache-independent.

- **`--incremental` fragment invariants.** Fragments must carry the module's
  `ignoredEdgesRef` + `methodProvidersRef` contributions — a `Skip`ped module never
  runs `compileDef`, so without them `contractIgnoredEdges` loses every edge through
  its with-/where-helpers. The slices must be before/after `ModuleEnv` deltas, not
  name-prefix filters: Agda homes module-instantiation copies at bare
  `_.…`/prefixless QNames.

- **`--packed-analytical` parity is by construction; `access` is 3-valued.** The
  analytical packed arrays (`kinds` / `lines` / `access` / `types` / subterm CSR)
  must agree node-for-node with expanded. Parity comes from sharing the per-QName
  lookups (`mkDefKind` / `mkDefLine` / …) between `toExpandedGraph` and
  `buildGraphJson` — don't inline them per-form. `access` stays 3-valued (`0`=
  unknown/absent, `1`=public, `2`=private): expanded omits `access`/`line`/`type`
  for QNames with no local `ADDef`, and `0` round-trips to that omission. Gate:
  `schema/packed_analytical_check.py` (run both sides cold).

- **`--incremental` serialise skip (`SerialiseCache`).** The monolithic no-op skip
  needs BOTH guards: `not anyRecompiled` (per-def content) AND a matching
  `outputToken` (module set + output-affecting options + build identity). Drop
  either and it serves stale output, so `outputToken` must list every
  output-affecting option (same discipline as `NFData Options`). The lazy per-module
  skip is content-epoch based (`mdjEpoch`). Bump `fragmentFormatVersion` on a
  payload-shape change; `optionsFingerprint` must list every flag that changes
  fragment content. Disabled under `--keep-going`.

## State semantics

Every definition carries one of four states:

- **`D` Defined.** Elaborated normally: a `Function` with clauses, a `Datatype`,
  `Record`, `Constructor`.
- **`P` Postulate.** Body is `Axiom{}` — user `postulate` or an Agda primitive.
- **`H` Hole.** Contains an unsolved meta. Signals: the QName starts with
  `unsolved#meta.` (Agda's `openMetasToPostulates` rewrites open metas under
  `--allow-unsolved-metas` — but only for *imported* modules; the main module's
  metas stay live in the meta store), the def references such a name, or a walk
  of `defType`/`theDef` finds an open `MetaV`.
- **`F` Failed.** **Module-level**, not def-level. Synthesised by `--keep-going`
  when a module's type-check raised `TCErr`: a marker node carrying the module
  name. Read as "we tried; contents not available".

Wire encoding: packed → `Int8` byte (0/1/2/3); expanded + the HTML-consumed
`graph.json` → letter `"D"` / `"P"` / `"H"` / `"F"`.

**Silent unsolved metas are split from honest `?`s — additively, not via a new
state.** Under `--allow-unsolved-metas` both an interaction `?` and a
silently-inserted unsolved meta (missing record field, failed instance search,
unsolved `_`) classify `H`, and `failedModules` stays empty — but plain `agda`
rejects only the silent kind (`UnsolvedMetaVariables` vs
`UnsolvedInteractionMetas`). The split survives to backend time through
`iHighlighting`: Agda's `warningHighlighting` marks each silent meta's range
with the `UnsolvedMeta` aspect (constraints: `UnsolvedConstraint`) *before*
`openMetasToPostulates` runs, and interaction metas get no aspect. Two signals,
one per module kind: imported modules → `unsolved#meta.*` markers whose
binding-site offset is tested against those spans (`Deps.markerIsSilent`, spans
memoised per process in `silentSpansCacheRef`); the main module (never
postulated) → live open metas minus `getInteractionMetas`. Emitted as a per-def
`unsolvedMetas` count (`_unsolvedMetas`; expanded omits 0, packed-analytical
`Int32` array) and a top-level `unsolvedModules :: Map module {metas, constraints
:: [line]}` rollup computed in `postCompileAD` (`unsolvedInterfaceLines` +
`liveSilentMetaLines`, the latter attributed to the entry module). No new flag,
no `v`/`nodeKeyVersion` bump. Identical Agda API on 2.8/2.9 — no CPP. Fixture:
`test-unsolved/` (locked by CI; kept outside `test/` so the main corpus needs no
flag).

**Soundness escapes are orthogonal to `state`.** Escapes beyond postulates/holes —
a `{-# NON_TERMINATING #-}` function or a `primTrustMe` body — go in a separate
optional per-def `unsafe` array (`UnsafeTag` in `Deps.hs`; wire tags
`non-terminating` / `trustme` in `Wire.hs`). Always computed, omitted when empty.
Emitted in expanded (`unsafe: [...]`) and packed-analytical (an `Int8` bitmask: bit
0 = non-terminating, bit 1 = trustme). Don't tag `{-# TERMINATING #-}`: the ordinary
termination checker sets `funTerminates = Just True` too, so it's indistinguishable
from a normal proof. Direct-use only; transitive taint is a consumer query. Fixture:
`test/Unsafe.agda`.

**File-level option escapes are module-level.** A whole-module escape via a file
pragma (`{-# OPTIONS --type-in-type #-}`, `--no-positivity-check`, `--rewriting`, …)
is a property of the interface, so it is a separate optional top-level
`moduleOptionEscapes :: Map module [String]`. Computed in `postCompileAD` from each
interface's **`iFilePragmaOptions`** (the file's own `OPTIONS` tokens), filtered
through `Deps.optionEscapes` / `safetyRelevantOptionFlags` (Agda's unconditional
single-flag `unsafePragmaOptions` — re-sync on an Agda bump). Use
`iFilePragmaOptions`, not `iOptionsUsed`: the latter folds in command-line + library
defaults and would misattribute e.g. `--lenient-imports` to every module. Not
captured (pinned by `test/OptionEscapes.agda`): per-block declaration pragmas
(`{-# NO_POSITIVITY_CHECK #-}`) and combination-conditional escapes (`--without-K` +
`--flat-split`). Omitted when empty. No CPP: `iFilePragmaOptions` is identical in
2.8 and 2.9.

## v2 graph.json schema

All HTML views consume the v2 schema; `--format=json` emits it directly. The
**expanded** form has a JSON Schema at
[`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json)
(draft 2020-12). `required` covers the fields present since v2 inception; additive
fields (`nodeKeyVersion`, `producer`, `definitionEdgesProvenance`,
`definitionSubterm*`, `externals_summary`, `moduleOptionEscapes`, per-def
`line`/`access`/`type`) are optional and `additionalProperties` is open, so it
validates older and forward-compatible output too. The `packed` form and `--lazy`
layout are not schematised.

**Single source of truth + drift check.** The expanded wire shape is described once
in `AgdaDeps.Backend.Wire` (field tables + a `SchemaDoc` ADT).
`agda-deps --emit-schema` regenerates the schema from it; CI
(`schema/check_schema.py`) fails if that diverges *structurally* from the committed
`schema/graph-v2-expanded.schema.json` (a frozen **oracle**). Emission goes through
the same tables (`buildExpandedJson` → `encodeExpanded`), so emitted bytes ≡
`Wire.hs` ≡ oracle by construction. Two more guards: `Wire.validateExpanded`
asserts cross-array length + edge-endpoint invariants the schema can't express; and
a committed golden (`test/golden/expanded.golden.json` + `schema/golden_check.py`)
catches content regressions after normalising out build/layout/path-volatile fields.

Three conventions for downstream consumers:

- **Schema version.** Every payload starts with `"v": 2`; expanded also emits
  `"schemaVersion": 2` and `"mode": "expanded"`. Refuse an unrecognised `v`.

- **Build provenance.** Both forms emit `"producer"` (the build's
  `BuildInfo.buildFingerprint`) and `"nodeKeyVersion"` (node-key convention). Both
  optional; absent `nodeKeyVersion` parses as `1`. Orthogonal to schema version: it
  tracks node naming, so a consumer can spot a stale cache whose wire shape is still
  v2 and rebuild.

- **JSON mode** (`--json-mode=packed|expanded`).
  - *packed* — CSR adjacency; per-def state in base64 typed arrays. Best for 100k+
    node projects. See `GraphJson.buildGraphJson`.
  - *expanded* — arrays of records keyed by qname / module name, no base64. Carries
    `schemaVersion` / `mode`, `kind` per definition, and a `reexports[]` array. An
    optional `definitionEdgesProvenance` array parallel to `definitionEdges`
    (`signature | body | module-local | with | unknown`) is always emitted; absence
    means "every edge `unknown`". Under `--with-signatures` each definition carries
    an optional `"type"` string (reified, Agda default printing, via `prettyTCM`). A
    `reexports[]` row that used `renaming` carries an optional `renames` map
    (`{alias: canonical-nodeKey}`), omitted when nothing was renamed. Computed by
    `collectReExports`. Expanded-only — packed / `--lazy` never emit `reexports`.

- **Lazy ingest path** (`--lazy`). Wire format split across files:
  - `graph.json` — module-level skeleton: `modules`, `moduleEdges` (index pairs),
    `moduleFiles :: Map String FilePath` (name → `modules/<Module>.json` — **the
    manifest**; walk it, never derive a URL from a module name, since non-safe names
    fall back to `detail-<hash>.json`), and `bundleFiles` (→ `snippets/<Module>.json`,
    only under `--with-source`).
  - `modules/<Module>.json` — that module's defs (`names`, `states`, `x`, `y`) plus
    outgoing leaf edges with `targetModule` annotations. `graph.json` also carries
    the richer module-level fields the views consume (`moduleStates`, `moduleDepth`,
    `modulePodLayout`, `fileTree`/`moduleTree`, `transitiveModuleEdges`, CSR
    `moduleToFile`/`fileToModules`), not yet formally schematised.

  Lazy output requires HTTP serving (browsers block `fetch()` on `file://`).

## Reference

- Prior art for the HTML view:
  <https://unimath.github.io/agda-unimath/VISUALIZATION.html>.
