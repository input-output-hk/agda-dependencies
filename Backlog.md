# Backlog

Deferred and refused ideas. For shipped work see [Changelog.md](Changelog.md);
for runnable recipes see [Examples.md](Examples.md); for forward-looking items
see [TODO.md](TODO.md).

---

## Deferred — would be useful, no current push

- **The `source-repository-package` pin** in `cabal.project` once
  Agda 2.9 lands on Hackage. It currently points at a specific upstream commit;
  bump it to track 2.9 fixes until release.


- **Multicore for the post-Agda passes.** Agda's `TCM` and the `Backend'`
  hooks are serial (upstream contract) and unsafe to fork. The post-Agda IO in
  `postCompileAD` — `backfillAccess`'s `findPrivateRanges` scan,
  `collectHighlightedSnippets`, the `Precompute` line scan — *would* be safe,
  but walltime there isn't dominant. Revisit on a profile.

- **Daemon / persistent mode (`agda-deps daemon`).** Amortise cabal+Agda
  startup (measured ~25 min over a 776-commit walk) by keeping one process
  consuming newline-delimited JSON commands. Large: Agda's `TCM` holds
  persistent state (`stDecodedModules` / `stVisitedModules` / mtime-based
  `.agdai` invalidation) that reuse across commits would touch. Cheaper win
  first: parallelise the walker's per-commit loop. (Calling the installed
  binary instead of `cabal run` is already possible — see the install recipe.)

- **Snippet bundle hashing for the `--skip-agda` drawer.** The
  `big-module-dag-pods` drawer keys defs by a Murmur-on-`prettyShow` hash that
  `SkipAgda` doesn't reimplement, so it shows a fallback. Add a JS-side hash or
  pre-bake a hash→name map into `graph.json` for a future
  `--skip-agda --with-source` mode.

- **Sub-modules in the source scan.** `Precompute.parseHeader` reads only the
  first `module …` per file; nested `module Foo.Inner where` blocks are missed.
  Fine for `--skip-agda` today.

- **Scale validation at 100k modules.** `big-module-dag-pods` has the right
  shape but is untested at that size; tune `BUCKET_SIZE` / `EDGE_BUDGET` /
  `VIEWPORT_PAD` from a real corpus when one's available.

- **External-module heuristic for `--skip-agda`.** A module is external iff its
  source is outside `cwd` or it appears only as an import target. Could grow to
  read `.agda-lib` `depend:` libraries for better multi-library classification.

- **Schema bump to v3.** `kind`, `reexports[]`, and `definitionEdgesProvenance`
  were all added additively under `schemaVersion: 2`. A v3 bump becomes honest
  at the next *incompatible* change.

- **Warm-`.agdai` edge loss.** A warm, non-incremental run emits a slightly
  poorer main-module graph than a cold run (dead-private pattern helpers lose
  edges/kind/type), because the `getSignature` dead-private recovery only sees
  `stSignature`, which holds just the entry module's defs. Main-module-only;
  imported modules are cache-state independent. Mitigated (the golden is a
  cold run; `--incremental` serves the complete fragment). A root fix would
  need recovering dead-private defs from outside `stSignature`.

## Refused / out of scope

- **Stable `def_id` across runs.** Refused on principle — belongs in a
  history/diff tool. Content/signature hashes and user pragmas are heuristics
  that break on refactors; QNames are the closest thing Agda ships and we
  already emit them. Rename detection is `git log --follow`'s job.

- **Inliner gap (producer side).** Won't fix on the producer: Agda inlines
  every `{-# INLINE #-}` call before the backend hook, so the call edges are
  unrecoverable from post-elaboration syntax, and keeping INLINE functions as
  nodes just creates zero-caller orphans that read as false `dead`. Handled
  consumer-side by a source scan. Fixture: `test/InlineGap.agda`.

- **`first_seen` / `last_seen`, per-commit `churn` / pivot hints.** Out of
  scope — multi-commit context is a history-tool concern. `first_seen` could
  become a daemon-mode field if the daemon ever lands.

- **Per-commit `present: [qname]` set.** Redundant — `defs.names` (packed) and
  `definitions[].name` (expanded) already enumerate every def seen this run.
