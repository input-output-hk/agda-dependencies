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
/ `html --lazy` / `json` over this corpus. Three fixture corpora live outside
`test/` so the main one needs no flags: `test-keepgoing/` (`--keep-going`),
`test-unsolved/` (`--allow-unsolved-metas`) and `test-matchconstant/`
(`AGDA_DEPS_MATCH_CONSTANT=1`, the unshipped phase-2 probe).

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
  MatchConstant.hs        A PROBE, not a feature: match-constant positions
                          (a case split replaceable by a wildcard), off the
                          compiled case tree. Emits nothing to the wire; runs
                          only under AGDA_DEPS_MATCH_CONSTANT. Measured and
                          rejected for the wire — see Backlog.md.
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
  - `Util.hs` — `funWith` is `Maybe QName` (2.8) vs `IsWithFunction QName` (2.9);
    and `ccDone`, because 2.9 turned the case tree's `Done` into a pattern
    synonym over `CCDone` with a clause number and a recursion flag in front of
    the bound-variable list. Both shims exist so their callers stay CPP-free.
  - `Help.hs` — `usageInfo` gained a leading column-width arg in 2.9.
  - `Main.hs` — 2.8 has no `runAgdaArgs`; shimmed via `withArgs` + `runAgda'`.
  - `Backend.hs` — `anameName` in `Scope.Base` (2.8) vs `Abstract.Name` (2.9).
  - `ModuleExplorer.hs` — `stCurrentModule` lazy `Maybe` (2.8) vs strict `:!:`
    (2.9); `setTCLens' stBackends` (2.8) vs `setSession lensBackends` (2.9);
    `unionSignature` is exported by `Monad.Signature` in 2.8 but gone in 2.9
    (its successor `importSignature` is private to `Interaction.Imports`), so
    2.9 gets a local mirror over the whole `Sig` record — keep that pattern
    exhaustive so a new field breaks the build instead of being dropped.

  In CPP modules, don't use backslash string gaps (cpp collapses them) — use `++`.
  Agda 2.9's `funProjection` is `Either ProjectionLikenessMissing Projection` —
  match `Right{projProper = Just _}`.

  Measuring on agda-stdlib: pass **both** `-i <root>` and `-i <root>/src`. The
  root `Everything.agda` does not sit under the library's own `include: src`, so
  with only one of them `--keep-going` tags it Failed and emits 0 definitions
  (this cost a build on each side of the consumer exchange).

  The 2.9 job is **opt-in**, so a 2.9-only break can sit in `main` unnoticed:
  build it locally (`cabal build --project-file=cabal.project.agda29
  --builddir=dist-agda29`) and re-run the golden against it before calling a
  change done. Watch `--with-signatures` in particular — `prettyTCM` resolves a
  qname against the *entry module's* scope, so a name reachable under two
  aliases can reify differently per version. `test/RenamedReexport.agda`
  re-exports `Nat`'s constructors, which is why no fixture type may mention
  `suc` (`test/ArgUsage.agda` indexes its `Vec` by a local `Idx` for exactly
  this reason).

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

- **Edge provenance (producer side).** `computeDefAD` (`Deps.tagOneWith`) walks
  `defType` and `theDef` separately: `defType` names → `Signature`; `theDef` names
  → `Body`, refined to `ModuleLocal` (wire `module-local`) when the target is an
  anonymous-module helper (`nrWhereHelper`). `module-local` is a property of the
  *target*. Precedence: `Signature > ModuleLocal > Body > Unknown`. Contracted
  edges inherit the source side's provenance; `addInstanceMethodEdges` adds
  `Unknown` with a left-biased `M.union`. Invariant: every kept edge has one tag
  and `M.keysSet _depsProv == _deps`.

- **There is no `with` provenance tag, and re-adding the old one is wrong.** One
  existed until 2026-08-31 and could never fire: it was emitted when a dep
  equalled the source's `funWith`, but `funWith` names a with-function's *parent*
  (`Monad/Base.hs`, `_funWith`) and is non-empty on **exactly** the defs
  `ignoreDef` drops (`isWithFun funWith`) — so the branch was only ever reachable
  while walking a def that is never emitted, and only for a *recursive* `with`
  (the helper must reference its parent). `contractIgnoredEdges` discards
  inside-chain provenance on top of that. Measured: zero `with` edges on a probe
  with nested `with` + a recursive `with`, on both 2.8 and 2.9; a dependency
  reached only through a with-abstraction arrives on the parent as `body`.
  Removing the tag changed no emitted byte (the golden was unaffected). The
  numeric slot 3 in `encodeEdgeProv` / `Binary EdgeProv` is left as a **hole** so
  the packed encoding of the surviving tags does not shift. A *meaningful* with
  signal would have to be applied at contraction time — a deliberate
  wire-content change, logged in [Backlog.md](Backlog.md), not a bug fix.

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

**Never-used arguments are read, not computed.** Agda already runs this analysis
for positivity/polarity checking (`Rules/Decl.checkPositivity_` → `computePolarity`,
for *every* mutual block, plain functions included) and serialises both lists into
the interface, so it is available cross-module with no re-checking. `Deps.argUsageOf`
reads `defArgOccurrences` + `defPolarity` off the `Definition` already in scope and
zips them: `Unused` + `Nonvariant` ⇒ **removable** (binder and every call-site
argument can go), `Unused` + anything else ⇒ **erasable** (used only in types, an
`@0` candidate). Emitted as the optional per-def `argUsage` object
(`{removable, removableRequires?, erasable, arity, binders?}`), omitted when there is
nothing to report — so finding-free corpora stay byte-identical. Always computed, no
flag. Identical API on 2.8/2.9 — no CPP. Fixture: `test/ArgUsage.agda`.

Seven things not to revert:

- **Indices are over the definition's *own* binders.** Agda prepends the enclosing
  section's telescope to every definition inside it, so the elaborated spine that
  `defPolarity`/`defArgOccurrences` index is longer than the signature as written: a
  `where` helper reports its *parent's* binders as removable, and they are not on its
  source line to delete. `argUsageOf` shifts the raw verdict down by
  `lookupSection`'s telescope size and drops anything landing in that prefix. Same
  hazard for `module M (n : Nat) where`. Regressions: `ArgUsage.helper@25` (2/[0],
  not 4/[0,1,2]), `ArgUsage.Section.{keeps,drops}`, and `test-keepgoing/Good.agda`'s
  `helper` for the `--keep-going` path. This deliberately makes `argUsage` indices
  *inconsistent* with the sibling `type` string, which still reifies the raw
  elaborated telescope — called out in the schema description; shifting `type` to
  match would be a wire-visible change to `--with-signatures` output.
- **`removable` needs the deletability guard; Agda's verdict alone is unsound.**
  `Unused` + `Nonvariant` answers "does the meaning depend on this value", not
  "can the binder be deleted". They differ when the argument occurs in the type
  only at an **irrelevant** position: `dependentPolarity` tests occurrence with
  `relevantInIgnoringSortAnn`, whose `RelevantIn` monoid *discards* occurrences
  under irrelevance (`withVarOcc o x | isIrrelevant o = mempty`,
  `TypeChecking/Free.hs`), so the position stays `Nonvariant` — while deleting the
  binder leaves the type naming something out of scope. Three shapes, all real on
  stdlib: an irrelevant binder (42 defs); a **relevant** binder whose only
  occurrence is at a callee's irrelevant argument position (5 — invisible to any
  test on the binder itself, so a consumer-side filter cannot substitute); and an
  occurrence **hidden by reduction** (20), where the codomain as written names the
  binder but the reduced one puts it in a later `Nonvariant` argument's domain,
  which Agda's rule discounts by design — so relevance-blindness alone is not
  enough. `guardDeletable`
  / `deletableRemovable` reject a position whose variable is free in the codomain
  or in a *surviving* argument's domain — Agda's own
  `relevantInIgnoringNonvariant` condition re-run with relevance-blind `freeIn`.
  Keep three things: the **exemption** for other surviving-removable domains (a
  jointly-removable chain is free in them by construction — without it every
  multi-index verdict dies, `ArgUsage.chain`); the **fixpoint** (rejecting one
  position strands earlier ones that only occurred inside it); and **both
  spines** — see the next bullet. Reported by the consumer repo; it affected 67 of
  145 stdlib `removable`-carrying defs (47 lost every finding, 20 lost some),
  244 → 142 positions, 145 → 98 defs. `erasable` is untouched by
  design: it claims an `@0` candidate, not a removal. Fixtures:
  `ArgUsage.{irrInCodomain,relAtIrrelevantPosition}` fire nothing,
  `ArgUsage.irrUnmentioned` still fires.
- **Occurrence questions need the syntactic spine *and* the reduced one.**
  `telView` reduces, which can **erase** an occurrence: a codomain `Irrel n p`
  whose `Irrel` ignores its second argument reduces to `Wrap n`, and the binder
  the source still mentions is gone. The syntactic spine (`piSpineOf`) is what a
  source edit must respect, but it stops at a type that only becomes a function
  after unfolding. So `Spine` is built both ways and either view may veto
  (`guardDeletable`, `removableRequiresOf`). **Descend with `absBody`, never
  `unAbs`**: a non-dependent `Pi` is stored as `NoAbs`, whose body is *not* under
  the binder, so `unAbs` silently mixes two de Bruijn index spaces and every
  occurrence test then answers about the wrong variable (this bug made
  `ArgUsage.chain` grow a phantom requirement before it was caught). `absBody`
  `raise`s a `NoAbs` body by one, which is why `telView` is safe. The sibling
  `piSpine` may use `unAbs` because it reads only hiding and names, never an index.
- **Truncation IS the padding rule.** Either list may be shorter than the
  arity; any index past the end of *either* counts as used. Deliberately more
  conservative than Agda's `getArgOccurrence`, which falls back to a `telView`
  computation for an out-of-range index — we want neither that cost nor that
  inference.
- **`binders` comes off the syntactic `Pi` spine, never a `telView`.** Hiding is in
  the domain's argument info and the name in the `Abs`, both on the spine Agda's own
  `arity` walks — so `Deps.piSpine` *replaces* that count (`max (length spine)
  analysed`) and the names cost what the count already cost, measurably nothing.
  `telView` would be wrong twice: it reduces, and a source binder name is not a fact
  reduction can reveal. Three consequences, each pinned: the spine can be *shorter*
  than the stored lists (`dependentPolarity` walked a reduced one), so a position
  past its end gets no entry — silence, not a guessed `explicit` (`ArgUsage.opaqueArg`,
  and 76 of 244 stdlib `removable` positions); the entries are re-indexed by
  `dropSectionPrefix` alongside the verdict, or a `where` helper reports its parent's
  binder *name* (`ArgUsage.Section.named` reports `m`, not `k`; `test-keepgoing`'s
  `helper` asserts the unnamed own binder against the parent's named `n`); and a name
  containing `.` (`A.a`) is a generalisation-inserted binder, kept as-is because it is
  what Agda's own printer emits and `.` cannot occur in a written binder name
  (`ArgUsage.genDependency`). `defGeneralizedParams` is *not* a usable marker for
  these — Agda fills it for data/record signatures only, so it is always `[]` on the
  `Function{}` path.
- **Only non-projection-like `Function`s (`droppedPars == 0`).** Projections and
  constructors drop parameters from both lists, so their indices are shifted off the
  telescope by exactly `droppedPars`; `Axiom`/`Primitive` have no body, and for
  `Datatype`/`Record` `enablePhantomTypes` purges `Nonvariant` parameters to
  `Covariant` so the signal means something else there.
- **`removable` with ≥2 indices may be a joint set — `removableRequires` says which.**
  `relevantInIgnoringNonvariant` ignores the domains of other `Nonvariant` arguments,
  so a chain like `(X : Set) → X → B → B` keeps both leading arguments `Nonvariant`
  only *because of each other*. `removableRequiresOf` recovers the actual constraint:
  `i` requires `j` iff `j > i` is removable and `i`'s variable is free in `j`'s
  domain, transitively. `computePolarity` has already ruled out every *other* place
  `i` could occur (the codomain or a non-`Nonvariant` domain would have demoted it to
  `Invariant`), which is what makes that the complete rule. The relation only ever
  points forward, so it is a DAG — plain DFS, no cycle check — and a shifted-away
  section prefix can never be a surviving requirement's target.

  Two corollaries worth keeping: for an analysable `Function`, `polFromOcc` is the
  *only* source of `Nonvariant` (`Unused ↦ Nonvariant`; `sizePolarity` and
  `dependentPolarity` only ever demote), so **`removable` ⟺ `Nonvariant`** and the
  two-field test is belt-and-braces rather than two independent facts. And because
  `dependentPolarity` demotes on the codomain *and* on every non-`Nonvariant`
  domain, a removable position's variable can only survive in another *removable*
  position's domain — so every closure ends at a binder the author actually wrote.
  That is why a generalisation-inserted position never needs its own wire marker:
  acting on its closure is always a well-defined source edit. Verified on the
  standard library — of the 15 provably inserted (dotted-name) `removable`
  positions, 0 have a closure without a written position.

  The reducing `telView` is paid only for a definition that already carries a
  `removable` finding — the gate is **≥1**, not ≥2, because round-4's
  deletability guard needs both spines even for a single position. It stays
  effectively never paid all the same: on agda-stdlib 2.4 the 98
  `removable`-carrying defs are the only ones that reach it, well under 1% of
  the corpus. Pinned by
  `ArgUsage.chain` (a chain: `{"0": [1,3]}`) and `ArgUsage.indep` (genuinely
  independent: no key at all — the case a symmetric "groups" encoding could not
  express).

**Phase 2 (`matchConstant`) was measured and rejected — and the reason is a trap
worth keeping.** `AgdaDeps.MatchConstant` finds positions whose case split could
be wildcarded. The obvious property ("every branch computes the same thing", i.e.
compare the branch bodies) is **unsound in a dependently typed language**: a match
also refines the branches' *types*, so `not-involutive true = refl;
not-involutive false = refl` has one identical body and still fails to typecheck
when wildcarded (`[UnequalTerms]`). On the standard library that shape was 101 of
102 raw candidates. Reporting therefore also requires the split variable to be
free in neither a later domain nor the codomain (`typeIndependent`) — a plain
occurrence check, *not* a re-implementation of `dependentPolarity`. Two further
non-obvious parts: a position counts only when **every** split on it in the tree
is collapsible (one argument can be split in several subtrees, and wildcarding
removes them all); and the index bookkeeping across a `Case` node is Agda's own
`splitC` convention (`ps0 ++ qs ++ ps1`) — a constructor branch of arity `k`
replaces the split position with `k` fields, a literal branch drops it, and the
catch-all keeps it, which is why the catch-all is treated as a slab of size 1.
Yield after the fix: 1 finding in 15,298 stdlib functions (0 in 6,795 from an
implementation-heavy corpus), and that one is `Data.Unit.NonEta.hide`, whose
stuck match is deliberate. Kept as a probe behind `AGDA_DEPS_MATCH_CONSTANT`,
pinned by `test-matchconstant/`; **delete it rather than fix it** if an Agda bump
breaks it.

Expanded-only: unlike the other analytical per-def fields there is no packed
counterpart, because a nested variable-length object has no typed-array shape (the
same reason `reexports` is expanded-only). `schema/packed_analytical_check.py`
enumerates the fields it compares, so it is unaffected.

## v2 graph.json schema

All HTML views consume the v2 schema; `--format=json` emits it directly. The
**expanded** form has a JSON Schema at
[`schema/graph-v2-expanded.schema.json`](schema/graph-v2-expanded.schema.json)
(draft 2020-12). `required` covers the fields present since v2 inception; additive
fields (`nodeKeyVersion`, `producer`, `definitionEdgesProvenance`,
`definitionSubterm*`, `externals_summary`, `moduleOptionEscapes`, per-def
`line`/`access`/`type`/`argUsage` (and within it `binders`)) are optional and
`additionalProperties` is open, so it validates older and forward-compatible
output too. The `packed` form and `--lazy`
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
    (`signature | body | module-local | unknown`) is always emitted; absence
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
