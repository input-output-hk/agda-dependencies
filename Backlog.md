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

- **`classifyExternalModules` misses pure re-export hubs.** Stdlib
  modules that only re-export from elsewhere never appear in
  `allQNames` and so slip past `--no-externals`. Now that
  `reexports[]` is populated, those hosts could be unioned into the
  classification input. ~5-line change.

- **Schema bump to v3.** `kind` and `reexports[]` were added at
  `schemaVersion: 2` (consumers ignore unknown fields, so strictly
  correct). The round-4 `definitionEdgesProvenance` field was also
  added under v2 — still additive, still backwards-compatible — but
  the surface area of v2 is growing. A v3 bump becomes honest at the
  next *incompatible* change.

---

## Refused — won't build, with rationale

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
