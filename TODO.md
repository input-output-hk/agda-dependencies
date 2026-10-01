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
  wire format, coordinated with the views in `agda-plotter` that read it.

- [ ] **Nodes and uses for INLINE functions, pattern synonyms and
  primitives.** These names get no definition node and no edge, so a consumer
  sees a use count of zero for some of the most-used names in a corpus:
  - `ignoreDef` drops `INLINE` functions on purpose: Agda has inlined every
    call site by the time the backend runs, so the bare node would be a
    false-"dead" orphan. On the Jolteon graph, all 10 `INLINE` definitions
    in agda-stdlib's `Function.Base` are missing (`_∘_`, `_$_`, `flip`,
    `case_of_`, …) and its other 25 are present.
  - It also drops `Agda.Primitive.Level`, primitive sorts (`Setω`) and
    primitives without clauses.
  - Pattern synonyms (`yes`, `no` in `Relation.Nullary.Decidable.Core`) are
    expanded before type-checking and never become definitions.

  Why it matters: agda-graph-explorer's `agda-unused` `public` check cannot
  judge a re-export of such a name. On Jolteon it withholds 20 findings: 8
  that name one (all genuinely used) and 12 blanket `open import … public`
  lines that bring one in, whose verdict stays unknown. Consumer side:
  `ctxDefinedKeys` in `AgdaUnused.Analysis`, and agda-graph-explorer's
  Backlog.md.

  What it needs:
  - **The node and its uses together, never the node alone.** A node without
    uses brings back exactly the false-dead orphan `ignoreDef` avoids.
  - **Uses from where the name is written, not from elaborated syntax**,
    which no longer holds an inlined call or a pattern synonym. Candidate
    source: the interface's highlighting, already read here for the
    unsolved-meta and unsolved-constraint spans. Check that its name aspects
    carry a definition site for an inlined call and for a pattern-synonym
    use before relying on it.
  - **Edge provenance.** An occurrence range says where a use is but not
    whether it is in the type or the body. Map it against the definition's
    ranges, or tag the edge `unknown`.
  - **Coordinate a new `kind` with the consumer first.**
    `AgdaGraph.Schema` refuses an unknown `kind` value at decode, so a
    `pattern-synonym` kind has to ship there before here. Marking an existing
    kind (e.g. an `inline` flag on a `function`) is additive and needs no
    coordination.
