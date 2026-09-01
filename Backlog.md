# Backlog

Deferred and refused ideas. Shipped work: [Changelog.md](Changelog.md).
Recipes: [Examples.md](Examples.md). Planned work: [TODO.md](TODO.md).

---

## Deferred — useful, no current push

- **Bump the `cabal.project.agda29` Agda pin to Hackage** once Agda 2.9
  releases (it currently points at an upstream `agda/agda` commit). The default
  `cabal.project` already tracks Hackage, pinned at Agda 2.8.0.

- **Multicore for the post-Agda passes.** Agda's `TCM` and the `Backend'` hooks
  are serial and unsafe to fork. The post-Agda IO in `postCompileAD`
  (`findPrivateRanges`, `collectHighlightedSnippets`, the `Precompute` scan) would
  be safe to parallelise, but its walltime isn't dominant. Revisit on a profile.

- **Daemon / persistent mode.** Amortise cabal+Agda startup by keeping one process
  consuming newline-delimited commands. Large: Agda's `TCM` holds persistent state
  (`stDecodedModules` / `stVisitedModules` / mtime-based `.agdai` invalidation)
  that cross-command reuse would touch.

- **Snippet hashing for the `--skip-agda` drawer.** `big-module-dag-pods` keys defs
  by a Murmur-on-`prettyShow` hash that `SkipAgda` doesn't reimplement, so it shows
  a fallback. Add a JS-side hash for a future `--skip-agda --with-source` mode.

- **Sub-modules in the source scan.** `Precompute.parseHeader` reads only the first
  `module …` per file; nested `module Foo.Inner where` blocks are missed. Fine for
  `--skip-agda` today.

- **Scale validation at 100k modules.** `big-module-dag-pods` has the right shape
  but is untested at that size; tune `BUCKET_SIZE` / `EDGE_BUDGET` / `VIEWPORT_PAD`
  against a real corpus.

- **External-module heuristic for `--skip-agda`.** Currently: external iff the
  source is outside `cwd` or it appears only as an import target. Could read
  `.agda-lib` `depend:` libraries for better multi-library classification.

- **Schema bump to v3.** `kind`, `reexports[]`, and `definitionEdgesProvenance`
  were added additively under `schemaVersion: 2`. A v3 bump becomes honest at the
  next *incompatible* change.

- **Warm-`.agdai` edge loss.** A warm, non-incremental run emits a slightly poorer
  main-module graph than a cold run (dead-private pattern helpers lose
  edges/kind/type), because `getSignature` recovery only sees `stSignature` (the
  entry module's defs). Main-module-only; mitigated because the golden is a cold
  run and `--incremental` serves the complete fragment.

- **A `with`-provenance tag that actually fires.** The old `with` value in
  `definitionEdgesProvenance` was removed on 2026-08-31 as unreachable (see
  [CLAUDE.md](CLAUDE.md) — `funWith` is non-empty on exactly the defs `ignoreDef`
  drops). A dependency reached *only* through a `with`-abstraction is a real and
  useful distinction, but the only place left to recover it is
  `contractIgnoredEdges`: when the hidden intermediary was a with-function, tag the
  contracted edge instead of inheriting the source's tag. That is a wire-*content*
  change — edges currently tagged `body` would become `with`, re-goldening this repo
  and the consumer's baselines — so it wants an explicit request, not a silent fix.
  The consumer repo has been told the tag is gone and is not building on it.

## Refused / out of scope

- **`matchConstant` (phase-2 `argUsage`): measured, rejected for the wire.**
  Positions whose case split could be replaced by a wildcard. Built as
  `AgdaDeps.MatchConstant` and measured under `AGDA_DEPS_MATCH_CONSTANT=1`
  (2026-08-31); the analysis is kept as a probe, emits nothing to the wire,
  and costs nothing unless the variable is set.

  **The design note's property is unsound in a dependently typed setting.**
  "Every branch computes the same thing" compares branch *bodies*, but a match
  also refines the branches' *types*. `not-involutive true = refl;
  not-involutive false = refl` has the identical body in both branches (a
  constructor's parameters are dropped in internal syntax, so `refl` is
  literally nullary) and yet `not-involutive _ = refl` is rejected with
  `[UnequalTerms]` — the split is load-bearing for type-checking. On the
  standard library that shape was **101 of 102** raw candidates. The fix is a
  plain occurrence check, not a re-implementation of `dependentPolarity`: report
  a position only when its variable is free in neither a later domain nor the
  codomain, so every branch shares one goal type.

  Yield after the fix, on two corpora:

  | corpus | functions with a case tree | sound findings |
  |---|---|---|
  | agda-stdlib 2.4 (`Everything`) | 15,298 | **1** |
  | Jolteon-FastBFT (implementation-heavy) | 6,795 | **0** |

  Phase 1's `removable` finds 98 defs in the same stdlib population, so this
  is ~98× below it — two orders of magnitude under the consumer's stated
  threshold. And the single finding is `Data.Unit.NonEta.hide`, whose match on
  a non-eta `unit` exists *precisely* to keep `hide f x` stuck: wildcarding it
  would defeat the definition's purpose. So the honest count of actionable
  findings across ~22k functions is zero.

  Kept so the number can be re-measured on any corpus (a proof-heavy library
  is the worst case for it; a programming-heavy one turned out no better).
  Pinned by `test-matchconstant/` + a CI step. **If it ever breaks on an Agda
  bump, delete it rather than fix it** — the measurement is done and the answer
  is recorded here.

- **Stable `def_id` across runs.** Belongs in a history/diff tool. Content/signature
  hashes and user pragmas break on refactors; QNames are the closest stable thing
  Agda ships, and we already emit them. Rename detection is `git log --follow`'s job.

- **Inliner gap.** Agda inlines every `{-# INLINE #-}` call before the backend hook,
  so the call edges are unrecoverable from post-elaboration syntax; keeping INLINE
  functions as nodes just creates false-`dead` orphans. Handled consumer-side by a
  source scan. Fixture: `test/InlineGap.agda`.

- **`first_seen` / `last_seen`, per-commit `churn` / pivot hints.** Multi-commit
  context is a history-tool concern.

- **Per-commit `present: [qname]` set.** Redundant — `defs.names` (packed) and
  `definitions[].name` (expanded) already enumerate every def seen this run.
