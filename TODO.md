# TODO

Forward-looking work on `agda-deps`. For runnable examples see
[Examples.md](Examples.md); for deferred / refused ideas see
[Backlog.md](Backlog.md); for shipped work see [Changelog.md](Changelog.md).

---

## Open

- [ ] **Drop the `source-repository-package` pin** in `cabal.project` once
  Agda 2.9 lands on Hackage. It currently points at a specific upstream commit;
  bump it to track 2.9 fixes until release.

- [ ] **Truly minimal lazy serialise.** A body-only edit already rewrites just
  the edited module's lazy file, but adding/removing a definition renumbers the
  dense global node indices the per-module `outEdges` embed, so many files'
  epochs change. Making that minimal needs a stable-per-node index in the lazy
  wire format, coordinated with the JS consumer in `agda-graph-explorer`.

## Shipped — see Changelog

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
