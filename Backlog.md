# Backlog

Deferred and refused ideas. Shipped work: [Changelog.md](Changelog.md).
Recipes: [Examples.md](Examples.md). Planned work: [TODO.md](TODO.md).

---

## Deferred — useful, no current push

- **Bump the `cabal.project` Agda pin to Hackage** once Agda 2.9 releases (it
  currently points at an upstream commit).

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

## Refused / out of scope

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
