# TODO

Forward-looking work on `agda-deps`. For runnable examples see
[Examples.md](Examples.md); for deferred / refused ideas see
[Backlog.md](Backlog.md); for shipped work see [Changelog.md](Changelog.md).

---

## Open

- [ ] **Truly minimal lazy serialise.** A body-only edit already rewrites just
  the edited module's lazy file, but adding/removing a definition renumbers the
  dense global node indices the per-module `outEdges` embed, so many files'
  epochs change. Making that minimal needs a stable-per-node index in the lazy
  wire format, coordinated with the JS consumer in `agda-graph-explorer`.

- [ ] **Module-level option escapes (soundness-escape Phase 2).** The per-def
  `unsafe` tags shipped (see below) cover `NON_TERMINATING` / `primTrustMe`,
  but *file-level* escapes — `--type-in-type`, `--no-positivity-check`,
  `--no-termination-check`, … — are properties of an interface's pragma
  options, not any one def. Emit a top-level optional
  `moduleOptionEscapes :: Map module [String]` read from each visited
  interface's recorded options in `postCompileAD`. Verify first whether a
  per-mutual-block `NO_POSITIVITY_CHECK` even survives into the interface; if
  only file-level pragmas are representable, document that. Phase 1 already
  covers the measured audit misses, so this is lower priority.

## Shipped — see Changelog

- **Soundness-escape `unsafe` tags (R12)** — optional per-def `unsafe` array
  (`non-terminating`, `trustme`), orthogonal to the untouched 4-state `state`
  enum; expanded + `--packed-analytical` (Int8 bitmask) + `--incremental`
  fragment (format v3). A `terminating-pragma` tag was dropped —
  `funTerminates = Just True` is written for every proven-terminating def, so
  it's indistinguishable from a normal proof. Consumer query surface (search /
  audit by `unsafe`) is tracked in `agda-graph-explorer`.

- **`renaming` aliases on re-exports (R14)** — optional `renames` map
  (`{alias-in-scope-name: canonical-nodeKey}`) on each expanded `reexport`
  row, omitted when nothing was renamed. Expanded-only. Consumer-side alias
  resolution (locate / type-of / search on the aliased name) is tracked in
  `agda-graph-explorer`.

- **`--incremental`** — P1 per-module fragment cache + P2 incremental
  serialise, plus cache GC and `--cache-dir`. Keyed on interface hash + option
  fingerprint + `nodeKeyVersion`. On a large corpus the dominant warm-rebuild
  cost is Agda's own interface load, which a backend cannot avoid;
  `--incremental` removes our per-definition walk and the output re-emit, not
  that floor.

- **`--packed-analytical`** — packed `graph.json` carrying the per-def
  analytical fields (kind / line / access / type / subterm hashes) so a
  consumer keeps packed's ~5× size win without losing fidelity. Producer side
  done; the consumer's base64-LE + CSR decoder is tracked in
  `agda-graph-explorer`.
