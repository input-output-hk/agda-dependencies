# TODO

Concrete forward-looking work on `agda-deps`.

For runnable examples see [Examples.md](Examples.md). For deferred or
refused ideas see [Backlog.md](Backlog.md). For shipped work see
[Changelog.md](Changelog.md).

---

- [ ] **Drop the `source-repository-package` pin** in `cabal.project`
  once Agda 2.9 lands on Hackage. The pin currently points at a
  specific upstream commit on `github.com/agda/agda` master; bump it
  to track 2.9 fixes until release.

---

## Incremental rebuild — per-module fragment cache

**Status:** designed + profiled 2026-06-12, not yet implemented.
Promoted from [Backlog.md](Backlog.md) after the cost was measured and
the design validated against Agda's backend API.

### Why (measured, not guessed)

A full run on a 16,769-definition reference corpus (17,995 unique
QNames, 6,080 module-import edges), **warm `.agdai` cache**,
`--format=json --json-mode=packed`, breaks down as:

| phase | wall time | share |
|-------|-----------|-------|
| Agda load + our `compileDef`/`postModule` walk + aggregation | ~127 s | 84 % |
| contract edges + instance edges + access backfill + layout | < 1 s | ~0 % |
| serialise + write (26 MB) | ~24 s | 16 % |
| **total** | **~151 s** | |

Standalone `agda -i . Everything.agda` on the same warm cache returns in
**~8 s**. So Agda's own interface loading is ~8 s; the remaining
**~119 s (79 % of the run) is our per-definition backend work** — the
`namesIn` walk over `defType` + `theDef` and the `postModuleAD`
`getSignature` dead-private-def diff, repeated for all 16,769 defs on
*every* rebuild even when one module changed. Layout is **not** a factor
(the >3000-node grid fallback is instant; sfdp only runs on small
graphs). This is the cost the cache removes.

### Why it's tractable (slots into the existing dataflow)

Two structural facts make this a localised change, not a rewrite:

1. **Agda already exposes the incremental primitive.** `preModule ::
   … -> tcm (Recompile menv mod)` where `Recompile menv mod = Recompile
   menv | Skip mod`. Returning `Skip m` tells Agda *not* to call
   `compileDef`/`postModule` for that module and to reuse `m` as its
   result. Our `preModule` (`moduleSetup`) currently *always* returns
   `Recompile`.
2. **Aggregation is already module-keyed and pure.** `type ModuleRes =
   [Maybe ADDef]`, and `postCompileAD` folds the
   `Map TopLevelModuleName [Maybe ADDef]` Agda hands it
   (`concat . M.elems`) — there is no global compile-time accumulator to
   keep coherent. A `Skip`'d module's cached `[Maybe ADDef]` flows into
   that map identically to a freshly-compiled one, and every downstream
   pass (contraction, instance edges, access backfill, layout, render)
   runs on the merged set unchanged.

### Design

- **Cache unit:** the value `postModuleAD` returns for a module — the
  final `[Maybe ADDef]` *including* the recovered dead-private extras
  (so a `Skip` reproduces `postModule`'s full output, not just
  `compileDef`'s). Serialise per module to
  `<cacheDir>/<Module>.fragment` (cacheDir defaulting under the output
  dir or a dotfile; behind an opt-in `--incremental` flag at first).
- **Cache key:** `(Agda interface hash, nodeKeyVersion, content-option
  fingerprint)`. Agda's `iFullHash` already folds in the transitive
  imported-interface hashes — the same mechanism that decides `.agdai`
  validity — so a key built on it is invalidated exactly when a
  dependency change alters this module's elaborated defs. `nodeKeyVersion`
  guards the node-naming convention (same rationale as the `graph.json`
  stamp). The option fingerprint covers flags that change fragment
  *content* (`--with-signatures`, `--normalise-signatures`,
  `--signature-implicits`, `--with-term-hashes`, `--min-term-depth`,
  `--with-source`, `--exclude`, …); a mismatch forces recompute.
- **Flow:** `preModule` looks up the fragment by key → hit ⇒
  `Skip cachedFragment`; miss/new ⇒ `Recompile` (current path), and
  `postModule` writes the fresh fragment before returning.

### Correctness invariants

- **Closed-change set in a green build.** Edges are stored by qname on
  the *source* def, so only changed modules need recompute. If a
  dependency's *public* API changed, this module's interface hash
  changes too (Agda re-checks it), so it's a cache miss — no dangling
  cross-module edge can survive. This holds only for a fully
  type-checked project.
- **`--keep-going` disables fragment caching** (or caches only
  successfully-elaborated modules). A failed module breaks the
  consistency the invariant above relies on; fall back to the full path.
- **Cache fresh-checked fragments, not warm-loaded ones.** Output is
  already not byte-stable across `.agdai` state today — a warm load
  exposes a pruned `getSignature`, so the dead-private recovery emits a
  handful fewer *edges* than a cold run (see the "Warm-`.agdai` edge
  loss" item in [Backlog.md](Backlog.md)). A fragment written from a
  fresh check captures the complete edge set; reusing it on later runs
  makes output cache-state-independent — so this design *fixes* that
  latent non-determinism rather than inheriting it, provided fragments
  are only ever written on the `Recompile` (fresh) path.

### Phasing

1. **P1 — fragment cache.** The ~119 s → (only-changed-modules) win.
   Largest lever; self-contained in `Backend.hs` + a new
   `AgdaDeps.FragmentCache` (de/serialise `ADDef`).
2. **P2 — incremental serialise.** After P1, the ~24 s write dominates a
   small-change rebuild (~24 s of a ~32 s run). Patch only changed
   modules' slices of `graph.json` / the `--lazy` per-module files
   rather than re-emitting 26 MB. Pairs naturally with `--lazy`'s
   already-split layout.
3. **Not feasible as a backend:** skipping Agda's ~8 s interface load.
   Agda controls loading; a backend cannot avoid it. Cheap anyway.

### Open questions

- `ADDef` serialisation format + version (reuse the existing wire
  encoding, or a dedicated compact one?).
- Where `iFullHash` is reachable in `preModule` (interface may not be
  loaded at that point) vs. keying on the `.agdai` file hash directly.
- Cache GC / staleness for deleted modules.
- Couples with the consumer repo's serve-stale path — coordinate the
  rollout there.
