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
