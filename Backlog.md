# Backlog

Deferred ideas, refused requests, exploratory work that isn't ready to
be picked up. For shipped work see [Changelog.md](Changelog.md); for
runnable recipes see [Examples.md](Examples.md); for concrete
forward-looking items see [TODO.md](TODO.md).

---

## Deferred — would be useful, no current push

- **Multicore for `agda-deps` post-Agda passes.** `agda-deps`'s
  post-Agda passes are still single-threaded. Agda's
  `TCM` and the `Backend'` hooks (`compileDefAD`, `postModuleAD`,
  `moduleSetup`) are serial by the upstream contract and aren't safe
  to fork. What *is* safe is the post-Agda IO inside `postCompileAD`:
  `backfillAccess`'s per-file `findPrivateRanges` scan
  (`Backend.hs:312-314`), `collectHighlightedSnippets` per-QName
  (`Backend.hs:474-475`), and the pre-compile `Precompute` line scan.
  Walltime on these isn't currently dominant, so deferred until a
  profile shows otherwise.

- **Daemon / persistent mode (`agda-deps daemon`).** An earlier
  benchmarking pass measured ~25 min of cabal+Agda startup on a
  776-commit walk over a real corpus. Real problem. Ask was to
  amortise by keeping one long-running process
  consuming newline-delimited JSON commands. Several weeks of work
  (Agda's TCM holds persistent state via `stDecodedModules` /
  `stVisitedModules` / mtime-based `.agdai` invalidation; reusing
  that across commits touches all of it). Two cheaper wins still on
  the table first: (a) walker calls the **installed binary** instead
  of `cabal run` (~1.5 s → ~50 ms per commit), (b) parallelise the
  walker's per-commit loop. Revisit when (a) + (b) are exhausted and
  overhead still dominates.

- **Snippet bundle hashing for `--skip-agda` drawer.** The
  `big-module-dag-pods` drawer references a definition by its hashed
  key, but `AgdaDeps.SkipAgda` doesn't reimplement Agda's
  Murmur-on-`prettyShow` hashing — drawer renders a fallback message.
  Wire up a small JS-side hash, or pre-bake the hash → name map into
  `graph.json`, so the drawer can pull source snippets in a future
  combined `--skip-agda --with-source` mode.

- **Sub-modules in the source scan.** `Precompute.parseHeader` only
  reads the *first* `module …` declaration per file — nested
  `module Foo.Inner where …` blocks are missed. Acceptable for the
  current `--skip-agda` use case; revisit if a project relies heavily
  on nested modules.

- **Scale validation at 100k modules.** `big-module-dag-pods` has the
  right algorithmic shape but hasn't been pointed at a real corpus
  that size. Once one's available, tune `BUCKET_SIZE`, `EDGE_BUDGET`,
  `VIEWPORT_PAD` from measured behaviour rather than guesses.

- **External-module heuristic for `--skip-agda`.** Currently a module
  is external iff its scanned source is outside `cwd`, OR it appears
  only as an import target with no scanned source of its own. Could
  grow into recognising `.agda-lib` `depend:` libraries directly for
  better classification on multi-library projects.

- ~~**`classifyExternalModules` misses pure re-export hubs.**~~
  **SHIPPED 2026-06-13** — see [Changelog.md](Changelog.md). The
  re-export host + source module names (`collectReExports` over the
  visited interfaces) are pooled into the classification input, so an
  out-of-root hub that only `open … public`s (e.g. `Data.List`) is now
  seen and dropped under `--no-externals`. Additive — the test corpus
  has no external re-export hub, so the golden is unchanged.

- **Schema bump to v3.** `kind` and `reexports[]` were added at
  `schemaVersion: 2` (consumers ignore unknown fields, so strictly
  correct). The round-4 `definitionEdgesProvenance` field was also
  added under v2 — still additive, still backwards-compatible — but
  the surface area of v2 is growing. A v3 bump becomes honest at the
  next *incompatible* change.

- **Warm-`.agdai` edge loss (found 2026-06-12; understood + mitigated
  2026-06-12).** The emitted graph is not byte-stable across the
  `.agdai` cache state: a cold run and a warm run emit the same node
  set but a different *edge* set (on `test/Test.agda`: 213 vs 204
  definition edges; the lost edges are out-edges of Agda-generated
  pattern helpers `Test.Int-0` / `Test.Plus-0/1` / `Test.Var-0`).
  **Refinement from the `--incremental` work: this is a
  main-module-only phenomenon.** The `getSignature` dead-private
  recovery only ever fires for the entry module — `stSignature` holds
  only the main module's defs at backend time; imported modules'
  emission is a pure function of their (always-pruned) interface and
  is cache-state independent. Mitigations shipped 2026-06-12: the
  committed golden is now generated from a cold run and CI clears
  `.agdai` before golden-feeding runs; `--incremental` serves the
  complete (fresh-check) main-module fragment even on warm runs.
  Remaining gap: a warm, *non-incremental* run still emits the
  degraded main-module variant — fixing that at the root would mean
  recovering dead-private defs from somewhere other than
  `stSignature`. Deferred.

- ~~**`--keep-going` emits *no* graph on a real broken corpus — the
  partial pass dies before `postCompile` (found 2026-06-12).**~~
  **SHIPPED 2026-06-12** — see [Changelog.md](Changelog.md)
  ("`--keep-going` hardening"). The diagnosis below was close but
  attributed the death to the wrong sub-region: exit 120 is Agda's
  `ImpossibleError` — `__IMPOSSIBLE__` thrown as a **GHC exception,
  which `catchError` cannot catch** — so the per-module guards were
  blind to it; the trigger was `--with-signatures` reification dying
  in `infallibleSortKit` because the post-rollback partial pass had
  re-merged only interface *signatures*, not builtins.
  `mergeIfaceState` + `catchAllTCM` guards at every stage fix it;
  `test-keepgoing/` + a CI step lock the always-emit guarantee;
  validated on Jolteon-FastBFT with a broken `TestTrace` (exit 0,
  4841 defs vs. previously nothing). Two known limitations, both
  acceptable for best-effort: `failedModules` may name the importing
  parent rather than the failing leaf (`stCurrentModule` attribution),
  and `entryModule` is absent when the entry never elaborated
  (deliberate — the old behaviour reported a *wrong* entry). The
  cross-repo companion (serve-stale fallback in `agda-graph-explorer`
  `AgdaMcp.State`) is still open on the consumer side.

  <details><summary>Original analysis (historical)</summary>

  This was the headline robustness gap, proposed as a feature: a
  dependency / navigation tool must be **best-effort**. One broken
  module — a WIP proof, a scratch `TestTrace` — should not blind the
  explorer to the other 483 modules that type-check fine. Today it
  does, and that is exactly the failure mode that pushes downstream
  agents back to `grep` (cf. the consumer usage analysis: 307 CLI
  calls vs. ~20 organic MCP calls).

  **Repro (verified).** Jolteon-FastBFT corpus, entry `Main.lagda.md`,
  whose closure transitively imports
  `Protocol/Jolteon/Global/TraceVerification/TestTrace.agda:185`
  (a genuine `[UnequalTypes]` instance-resolution error — Agda cannot
  pick the `Monad` instance for a `_>>=_`, leaving unsolved metas
  `_x_1153` / `_tc_1163`). Run, as the `agda-explore` daemon invokes it:
  ```
  agda-deps --format=json --json-mode=expanded --no-externals \
    --keep-going --with-term-hashes --min-term-depth=3 --with-signatures \
    -i <proj> -o <out> <proj>/Main.lagda.md
  ```
  → **exit 120, no `deps.json` written.** The consumer
  (`agda-graph-explorer` `AgdaMcp.State.runOne`) reports
  `agda-deps produced no graph for … (exit 120)`, so every graph-backed
  MCP tool (`search` / `locate` / `callers` / `impact` / …) has nothing
  to query and the daemon goes dark.

  **Diagnosis (file:line, against `src/AgdaDeps/ModuleExplorer.hs`).**
  The partial path *is* reached — this is **not** a missing call:
  - `handleCheckError` (:170–184) runs: stderr shows
    `tagging 'Protocol.Jolteon.…TestTrace' as Failed:` (:178) and
    `483 module(s) loaded successfully before the failure.` (:182).
    It returns `Left` (:184), so `partialBackendInteraction`'s `Left`
    branch fires `partialCompilerMain` per backend (:166–168).
  - But `partialCompilerMain`'s post-fold progress log
    `emitted def-level data for N/M loaded module(s)` (:239–242) **never
    prints**, and neither do any per-module
    `skipping def-level recovery for '…'` breadcrumbs (`reportSkippedModule`,
    :264–271). So execution dies **between entering
    `partialCompilerMain` (:221) and the log at :239** — i.e. inside the
    un-`catchError`'d setup region at :226–238: `getDecodedModules` +
    `mapM_ visitModule` (:226–227), `setTCLens' stSignature
    emptySignature` + `mapM_ mergeIfaceSig` (:235–236), or
    `preCompile backend (options backend)` (:237). The per-module fold
    (:238, :245–253) *is* individually guarded; this prelude is not.
  - `postCompile` (:243) is therefore never reached, so nothing is
    serialized. The failure surfaces only as a bare exit 120 — no
    diagnostic — so from the outside it is indistinguishable from a
    crash.

  Candidate mechanism to check first: the failing module leaves
  **unsolved metavariables / a partial signature** in the persistent
  `stDecodedModules`, and `mergeIfaceSig`'s `HMap.union` into
  `stImports` (:258–262) or `preCompile` then trips on it. The existing
  keep-going test fixtures presumably use a cleaner error (e.g. an
  out-of-scope name) that does not leave dangling metas, which is why CI
  is green while this corpus fails. This also **contradicts the
  documented `--keep-going` guarantee** in `README.md` ("modules whose
  sub-tree never finished type-checking … still appear with their import
  wiring") — here not even the precomputed module-level wiring survives.

  **What already exists to build on** (so this is hardening, not
  greenfield): `runPartial` / `partialBackendInteraction` /
  `partialCompilerMain` (`ModuleExplorer.hs`); the `reportFailed`
  callback → `failedModulesRef`; `egFailedModules` in the schema
  (`agda-graph-explorer` `AgdaGraph.Schema`) and its consumer parse; and
  the `Precompute` module-level scan that `postCompileAD` already unions
  into the output (`Backend.hs`).

  **Suggested fixes (for the dev picking this up):**
    1. **Guarantee emission.** Make `postCompile` run and write a
       `deps.json` even when def-level recovery yields few/zero modules —
       wrap the :226–238 prelude so a throw there *falls through* to
       emission rather than aborting. At minimum the precomputed
       module-level graph + `failedModules[]` should always be written;
       a graph with import wiring and zero def edges is far more useful
       than no file.
    2. **Localize the actual throw** in :226–238 with a `-v`/debug build
       — confirm whether it is the signature merge (`mergeIfaceSig` /
       `setTCLens' stSignature`) or `preCompile`, and whether unsolved
       metas from the failed module are the trigger; if so, prune/skip
       meta-bearing or `failed`-tagged interfaces before the merge.
    3. **Don't swallow.** A partial pass that cannot emit should print
       *why* (which stage threw) instead of exiting 120 silently;
       wrap `partialCompilerMain` in its own diagnostic `catchError`.
    4. **Add a fixture**, in the style of `test/Collision.agda` /
       `test/InlineGap.agda`: an entry importing exactly one
       type-erroring module (ideally an instance-resolution error that
       leaves metas), asserting `deps.json` *is* produced, the broken
       module appears in `failedModules[]`, and the sibling modules'
       defs/edges survive. This locks the guarantee that CI currently
       misses.
    5. **Cross-repo companion** (file in
       `agda-graph-explorer/Backlog.md`): even with a perfect producer,
       `AgdaMcp.State` should fall back to the last-good snapshot (or the
       precomputed module-level graph) when a rebuild emits nothing, so
       the serve-stale daemon degrades instead of going dark on the first
       broken edit.

  **Pick up when:** this is the single biggest blocker to the tool being
  usable during active *proof construction* (its primary use case) — a
  corpus mid-edit almost always has at least one non-checking module.
  High value; arguably promote to [TODO.md](TODO.md) rather than leave
  deferred.

  </details>

---

## From the Jolteon-FastBFT agent-usage analysis (2026-06-12)

Source: `Jolteon-FastBFT/docs/MCP/UsageAnalysis.md` — a mining pass
over all 60 Claude-agent session transcripts in that consumer project
(organic behaviour, not battle-test probes). Producer-side items only;
consumer/MCP items live in `agda-graph-explorer/Backlog.md`.

- **Incremental rebuild (changed-module cones) — promoted to the
  Roadmap 2026-06-12; P1 SHIPPED 2026-06-12 as `--incremental`.**
  Profiled and designed; see
  [TODO.md](TODO.md) ("Incremental rebuild — per-module fragment
  cache") for what shipped vs. the open P2 (incremental serialise). The profile corrected the framing: on a warm `.agdai` cache
  Agda's own load is only ~8 s — the dominant cost (~79 % of a ~151 s
  run on a 16,769-def corpus) is *our* per-definition `compileDef` /
  `postModule` walk, re-run in full on every rebuild. Agda's
  `preModule` `Skip`/`Recompile` API + the already-module-keyed
  `postCompile` dataflow make a per-module fragment cache (keyed on the
  interface hash) a localised change rather than a rewrite. This is the
  root cost behind the consumer-side serve-stale item; both are worth
  having.

- **Where-helper node identity (battle-test E1, HIGH).** ~~The graph
  keys definitions by reified qualified name, so same-named
  `where`/anonymous-module helpers silently merge into one node.~~
  **SHIPPED 2026-06-05 — predates this analysis.** The mined
  transcripts captured pre-fix behaviour. `nodeKey` now suffixes
  `._.`-marked helpers with `@<binding-line>`, `hashQName`/wire
  `name`/edge endpoints all derive from it, and `nodeKeyVersion` is
  bumped to `2` so a stale-format cache is detectable. Regression is
  baked into `test/Collision.agda` (imported by `test/Test.agda`):
  `useA ⇝ QED@20 ⇝ targetA` and `useB ⇝ QED@26 ⇝ targetB` both
  survive. See [Changelog.md](Changelog.md) (2026-06-05) and the
  `nodeKey` gotcha in [CLAUDE.md](CLAUDE.md). Do not re-implement.

- **Inliner gap, producer side — investigated 2026-06-12, deferred with
  evidence.** Agda inlines every call to an `{-# INLINE #-}` function
  into the caller's body *during type-checking*, before the backend
  hook fires, so `agda-unused` reports such live definitions as `dead`
  (three confirmed FPs in the consumer project; agents grep-verify every
  `dead` finding, halving the tool's value). Characterised with a
  fixture (`test/InlineGap.agda`, imported by `test/Test.agda`):
  - The INLINE helper `twice` is dropped as a node by `ignoreDef`'s
    `funInline` rule, and its callers `useInline` / `aliasTwice` point
    straight at `Nat._+_` (the inlined body), never at `twice`.
  - The lost `⇝ twice` edges are **not** a contraction artefact: with
    the `funInline` drop disabled, `twice` reappears as a node but the
    callers *still* point at `_+_`. The call edges are genuinely absent
    from the elaborated `Defn` the Backend receives — Agda replaced the
    call with the body upstream of `compileDefAD`.
  Conclusion: **the full producer fix is not achievable from the
  post-elaboration internal syntax** (`compileDef` has no pre-inline
  view; recovering the edges would mean walking abstract syntax /
  hooking before Agda's inliner, the "principled-but-complex" option).
  And the cheap partial step — keeping INLINE functions as nodes — is
  **net-negative**: every call site is inlined away, so the node is
  always a zero-caller orphan that dead-code analysis flags as a false
  `dead`. So the `funInline` drop stays (now with a don't-revert note in
  `ignoreDef` + the CLAUDE.md gotcha), and the **consumer-side
  source-scan union remains the right fix** (filed in
  `agda-graph-explorer`): the textual `twice m` call survives in source
  even when the elaborated edge does not.

- **Stable installed binary path.** ~30 transcript Bash calls were
  pure binary archaeology (`find dist-newstyle -name agda-deps`,
  launcher checks, mtime-vs-commit forensics). Confirms the filed
  launcher-staleness items (consumer F3.2/F4.3/F5.2/F6.1) from the
  usage side; a `cabal install`-style stable path removes the class.

From an external batch of 14 numbered feature requests, 9 shipped
(#1, #2, #3, #4, #5b, #8, #9, #10, #11), 1 was already done (#5), and
these are the rest.

### #5 — Schema-version stamp on the JSON output

Already done. Every payload starts with `"v": 2` as its first field —
that *is* the schema version. The expanded form additionally emits
`"schemaVersion": 2` and `"mode": "expanded"` for clarity. A consumer
wanting fail-fast on schema skew:

```python
graph = json.loads(open("deps.json").read())
if graph.get("v") != 2:
    raise SystemExit(f"agda-deps schema v{graph.get('v')} unsupported")
```

### #7 — Stable `def_id` across runs

Refused on principle; belongs in a history / diff tool, not in agda-deps.

Each suggested shape breaks on a slightly different refactor:

- Content hash breaks on whitespace, comment, let-bound variable
  renames.
- Signature hash breaks on type-signature refactors.
- User-supplied pragma requires every Agda developer to annotate.

None of these is "stable identity"; they're heuristics that look
stable until they don't. **Agda itself has no notion of stable
identity** — QNames are the closest thing it ships, and we already
emit them. Layering rename detection on top is exactly what
`git log --follow` does for files: it lives in the *history tool*,
not the snapshot tool.

### #12 — `first_seen` / `last_seen` per qname in lazy archives

Out of scope (author marked it so). agda-deps is single-shot.
Multi-commit context is a history-tool feature. If #6 (daemon) ever
lands, this could plausibly become a daemon-mode-only field.

### #13 — Per-commit `churn` / pivot hints

Out of scope (author marked it so). Cross-commit comparison is a
history-tool concern.

### #14 — Stable per-commit `present: [qname]` set

Redundant. `defs.names` (packed) and `definitions[].name` (expanded)
already enumerate every definition agda-deps saw this run. Consumers
that want just presence can parse only those fields.
