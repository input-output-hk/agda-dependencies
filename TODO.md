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

**Status:** P1 + P2 SHIPPED (2026-06-12 / 2026-06-13) as `--incremental`
(see [Changelog.md](Changelog.md)). Cache GC + `--cache-dir` also
shipped. Implementation notes vs. the design below:

- **P2 (incremental serialise) shipped** in `AgdaDeps.SerialiseCache`:
  monolithic no-op skip (`recompiledRef` + `outputToken`) and lazy
  per-module skip (`mdjEpoch`). **The profiling premise was off for
  large corpora:** on Jolteon (warm cache) the dominant cost is Agda's
  own interface load (~96 s, unavoidable as a backend), the post-Agda
  aggregation is ~40 ms, and serialise+write of the 12 MB lazy output
  is sub-second — so P2 pays off on /output-heavy/ runs (monolithic
  expanded with signatures/term-hashes ≈150 MB; `--with-source`
  bundles) and no-op rebuilds, not on the Agda-load floor. The 26 MB
  reference corpus where "serialise was 16 %" had a ~8 s load; Jolteon's
  load is 12× that.
- **Cache GC + `--cache-dir` shipped:** stale `*.frag` for
  deleted/renamed modules are pruned each `--incremental` run; the
  cache location is overridable.
- **Still open — truly minimal lazy serialise.** A body-only edit
  already rewrites just the edited module's lazy file, but
  adding/removing a definition renumbers the dense global node indices
  the per-module `outEdges` embed, so many files' epochs change. Making
  that minimal needs a stable-per-node index in the lazy wire format,
  coordinated with the JS consumer in `agda-graph-explorer`. Deferred.

P1 implementation notes vs. the design below:

- The cache unit / key / flow landed as designed
  (`AgdaDeps.FragmentCache`; key = format version + content-option
  fingerprint + `iFullHash` + `nodeKeyVersion`).
- **The design missed the side-channels:** a `Skip`ped module never
  runs `compileDef`, so its `ignoredEdgesRef` / `methodProvidersRef`
  contributions must ship inside the fragment or contraction silently
  drops edges through its with-/where-helpers. Fragments now carry
  both slices, computed as exact before/after deltas (`ModuleEnv`
  snapshots) — name-prefix slicing missed anonymous-module copies
  (`_.…` QNames) and lost ~12k edges on Jolteon.
- **The fresh-check gate only matters for the main module.** The
  `getSignature` dead-private recovery only ever fires for the entry
  module (imported modules' defs are not in `stSignature` at backend
  time), so imported modules are cached unconditionally and the
  warm-`.agdai` edge loss is a main-module-only phenomenon.
- Serialisation rides Agda's `EmbPrj` (exact `QName` round-trip);
  byte layer (`Agda.Utils.Serialize`) is 2.9-only, so on the 2.8 build
  the flag warns and degrades to no caching.

Original design (kept for the P2 follow-up):

**Status (historical):** designed + profiled 2026-06-12.
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

---

## Packed-complete — a consumer-usable packed form

**Status:** proposed 2026-06-13. Requested after the consumer
(`agda-graph-explorer`) confirmed it **cannot** load today's packed form;
it now refuses packed with an actionable error and documents the gap in
`agda-graph-explorer/test/packed/README.md`.

### The problem

`graph.json` has two shapes. **expanded** (`--json-mode=expanded`) is what
the analysis consumers parse (`AgdaGraph.Schema` in the explorer repo:
`agda-unused`, `agda-optimization`, `agda-explore`). **packed**
(`--json-mode=packed`, the default) is ~5× smaller — base64-encoded
little-endian typed arrays + CSR edges — but is built for the **HTML
viewer**: its `defs` object carries only `names`, `modules`, `states`,
`x`, `y`.

It **omits every per-definition analytical field** the consumers need:

| field (expanded) | consumed by | in packed? |
|------------------|-------------|-----------|
| `kind`           | `search`/`roots --kind`, `locate`, primitive detection | ✗ |
| `line`           | `locate` file:line, the where-helper owner map | ✗ |
| `access`         | `agda-unused` public/private | ✗ |
| `type` (signature, `--with-signatures`) | `type_of`, `find_lemma`, `similar_types` | ✗ |
| subterm hashes/depths (`--with-term-hashes`) | `similar_bodies`, `term-cluster` | ✗ |

So a consumer can only have the size win **or** analytical fidelity, never
both. On a large corpus that hurts: the Jolteon-FastBFT expanded graph is
**174 MB** — slow to write here, slow to read + hold in the
`agda-explore` daemon. Packed would cut that ~5× but is unusable for the
tools an agent actually leans on (`type_of`, `similar_*`, `find_lemma`,
`unused`).

### What to build

A packed form that keeps the compact encoding **and** carries the
analytical fields — either a new `--json-mode=packed-complete` or, simpler,
an additive flag (e.g. `--packed-analytical`) that augments `packed`'s
`defs` object (the HTML viewer ignores the extra keys, so it can even be
on by default). Concretely, add these arrays **parallel to `defs.names`**:

- `defs.kinds` — base64 **Int8** (enum `0..7`:
  function/projection/datatype/record/constructor/postulate/primitive/other).
- `defs.lines` — base64 **Int32** (`-1` = unknown).
- `defs.access` — base64 **Int8** (`0`=public, `1`=private).
- `defs.types` — JSON `[string|null]` parallel to names, emitted only under
  `--with-signatures` (text, so it stays JSON, not a typed array; a shared
  string table is a later optimisation).
- `defs.subtermHashes` / `defs.subtermDepths` — variable-length per def, so
  CSR-style: a shared `defs.subtermOffsets` (base64 Int32, `nDefs+1`) plus a
  flat `defs.subtermHashes` (base64 **Int64** LE; the canonical Word64
  hashes) and `defs.subtermDepths` (base64 Int32, same offsets). Emitted
  only under `--with-term-hashes`.

All reuse the existing little-endian typed-array encoders in
`AgdaDeps.Backend.Csr` (`encodeInt8LE`/`encodeInt32LE` + a new
`encodeInt64LE`) and slot into `defsObjectJson` in
`AgdaDeps.Backend.GraphJson` next to the existing `modules`/`states`/`x`/`y`
arrays. No edge/topology change — `edges` (CSR), `definitionEdgesProvenance`,
modules, etc. are already complete in packed.

### Why it's worth it

- **Size + IO + memory on big corpora.** The consumer daemon loads the
  whole graph into memory; ~5× smaller JSON ⇒ faster parse, less RSS,
  faster serve-stale rebuild materialisation. This is the lever once a
  corpus (Jolteon-class) makes the expanded graph the bottleneck.
- **No fidelity loss.** Every consumer tool keeps working; the consumer
  switch becomes a pure encoding change, invisible to users.
- **Cheap producer change.** It's additive arrays in one function reusing
  existing encoders — no new walk, no recompute (the producer already has
  `kind`/`line`/`access`/`type`/hashes in hand when it builds expanded).

### Consumer side (already prepared)

`agda-graph-explorer` documented the packed layout + the gap in
`test/packed/README.md` (with a committed `Nat.{packed,expanded}.json`
example pair) and made `AgdaGraph.Schema` refuse packed with a pointer to
it. Once this lands, the consumer adds a fast decoder (base64-LE + CSR via
`base64-bytestring` + a `Storable` cast — **not** a hand-rolled bit loop,
to stay fast on a 174 MB graph) mapping packed-complete → `ExpandedGraph`.

### Acceptance gate

The decoded packed-complete graph must produce an **in-memory state
byte-identical to the expanded form** of the same corpus (same defs incl.
kind/line/access/type, same edges + provenance, same subterm
hashes/depths). The consumer asserts `decodePackedComplete(packed) ≡
loadExpanded(expanded)` on a committed fixture pair — that equivalence is
the definition of done.
