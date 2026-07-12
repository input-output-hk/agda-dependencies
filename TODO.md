# TODO

Forward-looking work on `agda-deps`. Runnable examples:
[Examples.md](Examples.md). Deferred / refused ideas: [Backlog.md](Backlog.md).
Shipped work: [Changelog.md](Changelog.md).

---

## Open

- [ ] **Truly minimal lazy serialise.** A body-only edit already rewrites just
  the edited module's lazy file, but adding/removing a definition renumbers the
  dense global node indices the per-module `outEdges` embed, so many files'
  epochs change. Making that minimal needs a stable-per-node index in the lazy
  wire format, coordinated with the JS consumer in `agda-graph-explorer`.
