# AGENTS.md

## Project

`agda-deps` is a Haskell executable and Agda compiler backend. It runs inside
Agda's type-checking pipeline and emits dependency graphs as DOT or v2 JSON.
Treat `graph.json` as a stable consumer-facing wire format.

HTML rendering is **not** in this repository. It lives in
[`agda-plotter`](https://github.com/input-output-hk/agda-plotter), which reads
the packed `graph.json` and links no Agda; graph *analysis* consumers live in
[`agda-graph-explorer`](https://github.com/input-output-hk/agda-graph-explorer).
Changes to the views, the `--view` catalogue or `--agda-html-dir` belong in
`agda-plotter`, not here.

Use these documents as the source of truth:

- `README.md` for supported behavior and CLI usage.
- `Examples.md` for runnable feature examples.
- `Changelog.md` for shipped changes.
- `TODO.md` and `Backlog.md` for planned or rejected work.
- `.github/workflows/ci.yml` for the complete validation matrix.

## Repository map

- `src/Main.hs`: argument preprocessing, project discovery, and Agda dispatch.
- `src/AgdaDeps/Backend.hs`: backend hooks and post-compile orchestration.
- `src/AgdaDeps/Deps.hs`: definition extraction, identity, filtering, states,
  edge contraction, and analytical fields.
- `src/AgdaDeps/NodeKey.hs`: the `QName` → node-key / module-key naming
  convention, shared by `Deps` and the subterm hasher (`TermCanon`).
- `src/AgdaDeps/Options.hs`, `Config.hs`, `Doctor.hs`: CLI and YAML surfaces.
- `src/AgdaDeps/Backend/Wire.hs`: canonical expanded-v2 field definitions and
  generated schema description.
- `src/AgdaDeps/Backend/GraphJson.hs`: packed, expanded, and lazy JSON output.
- `src/AgdaDeps/Backend/Dot.hs`: DOT renderer.
- `src/AgdaDeps/{FragmentCache,SerialiseCache}.hs`: incremental caches.
- `test/`: main Agda fixture corpus and expanded JSON golden.
- `test-keepgoing/`, `test-unsolved/`, `test-matchconstant/`: specialized
  regression corpora.
- `schema/`: schema oracle and drift/parity checks.
- `docs/site/`: Pelican generator; root Markdown files are the documentation
  sources and `docs/` is generated output.

## Build and run

The default build targets Agda 2.8:

```sh
cabal build
cabal run agda-deps -- -i test/ -o /tmp/agda-deps-check test/Test.agda
```

Everything after `--` is passed to the backend and Agda. Backend changes must
preserve Agda 2.8/2.9 behavior. Build the alternate project for changes that
can affect Haskell compilation or graph output; for graph-semantic changes,
also run its cold expanded golden check as shown in CI:

```sh
cabal build --project-file=cabal.project.agda29 --builddir=dist-agda29 agda-deps
```

There is no Cabal test suite. Run checks appropriate to the change; CI is the
authoritative full suite. For graph semantics, start cold by clearing
`test/*.agdai` and `test/_build`, then generate expanded JSON with
the analytical fields and compare it with the golden:

```sh
cabal run -v0 agda-deps -- --format=json --json-mode=expanded \
  --with-signatures --with-term-hashes -i test/ \
  -o /tmp/agda-deps-check test/Test.agda
python3 schema/golden_check.py check /tmp/agda-deps-check/deps.json \
  test/golden/expanded.golden.json
```

Only update the golden when the semantic change is intentional. For wire or
configuration changes, also run the schema generation/drift check,
`schema/packed_analytical_check.py`, and `schema/show_defaults_check.py` as shown
in CI. Documentation-only changes need at least `git diff --check` and link/path
review. Rebuild public docs with `make -C docs/site html`; do not hand-edit the
generated pages.

## Invariants

- Support both Agda 2.8 and 2.9. Isolate genuine API differences with
  `MIN_VERSION_Agda(2,9,0)` and keep shared callers CPP-free where practical.
  In CPP modules, concatenate strings with `++`; preprocessor handling makes
  backslash string gaps unsafe.
- Keep backend extraction single-threaded. Agda's `TCM` state and the backend's
  `IORef` side channels are not thread-safe.
- `ignoreDef` is the definition/noise boundary. Preserve its early `defCopy`
  check and `funInline` filtering. Hidden references must survive until
  `contractIgnoredEdges`; filter dependencies after contraction.
- Convert live `QName`s to serializable `NodeRef`s at producer boundaries. Use
  `nodeKey` for wire identity and `moduleKey` for module ownership everywhere.
  If the naming convention changes, bump `nodeKeyVersion` and coordinate the
  same change with downstream consumers — it now spans three repositories:
  this one, `agda-plotter` (`AgdaPlotter.Graph.expectedNodeKeyVersion`), and
  `agda-graph-explorer`.
- The packed form is the renderer's contract and the expanded form is the
  analysis tools'. `--lazy` splits the packed form only: `giLazy` moves `defs`
  and `edges` out of `graph.json` into `modules/<Module>.json` and adds the
  `moduleFiles` manifest. `buildExpandedJson` ignores `giLazy`, so
  `--json-mode=expanded --lazy` is inert by design and says so.
- The four state colours are duplicated in `agda-plotter`, not shared — nothing
  carries them on the wire. `defaultPalette` and `themePalette` must stay
  byte-equal across the two repositories or DOT and HTML renderings of one
  project disagree.
- `Backend.Wire` is the expanded-v2 source of truth. Keep generated output,
  `schema/graph-v2-expanded.schema.json`, validation, and the golden aligned.
  Make new v2 fields additive and optional unless a deliberate versioned
  breaking change is being made.
- Fields supported by packed analytical output must decode node-for-node to
  their expanded equivalents. `argUsage` and `reexports` deliberately remain
  expanded-only. Share computations instead of reimplementing field logic.
- Golden generation must be cold: a warm main-module `.agdai` can skip
  dead-private recovery and produce an incomplete graph.
- Incremental fragments must preserve every per-module side-channel slice.
  Reset side channels centrally. Bump `fragmentFormatVersion` for payload shape
  changes, and update option fingerprints/output tokens for every option that
  changes cached content or serialized output.
- Preserve the argument-usage analysis's reduced-versus-syntactic telescope
  distinction, section-prefix shifting, deletability fixpoint, hidden-binder
  guard, conservative body-occurrence handling, and whole-corpus
  partial-application backfill. `test/ArgUsage.agda` contains the regressions;
  do not replace these rules with a simpler occurrence check.
- `AgdaDeps.MatchConstant` is a measurement probe, not a wire feature. It runs
  only under `AGDA_DEPS_MATCH_CONSTANT`; do not expose it in `graph.json`.

## Extending the tool

When adding an option, update `Options`, `defaultOptions`, and
`commandLineFlags` (the `NFData` instance is `Generic`-derived); update the
YAML `Config` record, `defaultConfig`, `FromJSON`, `applyConfig`, and
`showDefaultsYaml`; then update
`Doctor.knownFields` and add a coherence rule when combinations can be
ineffective. Merge precedence remains defaults, then config, then CLI. Enum
values belong in the shared `allFormats`, `allJsonModes`, or `allThemes` tables.
Follow the cache-fingerprint rule above when applicable. If the option changes
the emitted bytes, it must also be listed in `Backend.outputToken`, or the
`--incremental` no-op skip serves stale output.

Adding or changing an HTML view is work for the `agda-plotter` repository. Do it
there. What belongs here is only the data a view needs: add it to the shared
JSON contract, keep it view-agnostic, and bump the versions named below if the
shape changes.

Keep changes focused, preserve unrelated worktree files, and avoid committing
generated run output or caches unless the fixture or documentation update is
explicitly part of the change.
