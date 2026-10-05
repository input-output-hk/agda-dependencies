# Changelog

## 2026-10-05 — `--keep-going` collects all checkable project files

- `--keep-going` / YAML `keep-going` now checks the command-line entry and every
  discovered project source independently, then writes one graph containing
  successful roots and their loaded dependencies. Type errors, parse errors,
  unresolved names and broken imports cannot stop later independent checks.
- Per-file state resets retain Agda's interface cache. Accepted roots are
  captured before reset, including their live hole metas and cold private
  definitions. Checking rules and `--safe` remain unchanged; file-local
  `--allow-unsolved-metas` pragmas permit incomplete implementations.
- Incremental output caching remains disabled under `--keep-going`.
  External include trees are dependencies rather than sweep targets;
  exclusions skip matching discovered roots. Failed requested files, including
  files blocked by dependencies, use the existing `failedModules` contract.
- CLI/config/defaults/doctor and output fingerprints are aligned. Regressions
  cover cold/warm expanded, packed and lazy output, analytical parity, holes,
  cycles, isolated and literate sources, source-only headers, exclusions,
  physical containment, entry identity and option isolation on Agda 2.8/2.9.
  Wire, node-key and fragment payload versions are unchanged.

## 2026-10-02 — optional structural type terms

- `--with-type-terms` / YAML `with-type-terms` adds a shared type-expression
  DAG, signatures, section-parameter counts and type-valued clause bodies
  with binder contexts to expanded JSON. `typeTerms.v` is 1; graph v2 and
  node keys v3 are unchanged. Default output omits the field.
- Capture preserves modalities and qualified identities, marks unsupported
  forms, and removes module-copy wrappers without broadly unfolding user
  definitions. It retains only final graph definitions and exports no
  fabricated expression source ranges or per-node types.
- Requires a non-incremental Agda run with expanded JSON; incompatible
  output/cache/skip flags fail before checking. CLI, config, doctor, defaults,
  generated schema and output fingerprints are updated together. Adds wire,
  Unicode and warm-interface checks on Agda 2.8 and the pinned 2.9 build.


History of notable changes to `agda-deps`. Reverse-chronological. For
runnable recipes see [Examples.md](Examples.md); for forward-looking
work see [TODO.md](TODO.md); for deferred / refused ideas see
[Backlog.md](Backlog.md).

---

## 2026-10-01 — `agda-deps` — retain isolated scanned modules in JSON

Normal JSON output now includes every scanned module that survives
`--exclude` and `--no-externals`, even if it has no definitions or import
edges. Previously an unimported module in an external include directory
could abort expanded output and silently disappear from packed and lazy
output. Source-only modules contribute no invented definitions, and lazy
output uses the existing empty placeholders.

Scanned paths fill gaps in module-to-file mappings while Agda binding paths
retain precedence. External inventories follow the module filters, and
`--no-externals` also filters scanned source paths by physical containment,
matching skip mode. Older incremental outputs refresh while keeping their
definition fragments. The wire and cache payload formats are unchanged.

CI regressions cover all JSON shapes, normal and skip modes, combined
filters, source-only modules, and incremental additions/removals under
Agda 2.8 and 2.9. Cold corpus output differs only by three added source-file
mappings; definition data is unchanged.

## 2026-10-01 — `agda-deps` — CLI colour overrides survive later themes

Explicit CLI `--color-*` choices now override `--theme` regardless of their
argument order. `--color-defined='#123456' --theme=dark` and the reversed
order both render definitions in `#123456`. Previously a later theme erased
the explicit colour. Repeated themes select the last theme; repeated colours
select the last value for each state.

Defaults → YAML → CLI precedence is preserved: a CLI theme replaces the YAML
palette, including YAML colour overrides, and explicit CLI colours then take
precedence. Startup and Agda parsing share the same rule, including skip and
keep-going modes. Invalid values still fail even if a later flag replaces them.

Regressions under Agda 2.8 and 2.9 cover all 120 placements of a theme and
four colour flags, actual DOT colours for all four states, repeated flags,
YAML interactions, and incremental reuse. Palette changes refresh output;
equivalent flag orders retain cached JSON. The wire and cache formats and
preset colour values are unchanged.

## 2026-10-01 — `agda-deps` — validate YAML colours and minimum term depth

Normal YAML loading now rejects malformed `color-*` values and
`min-term-depth` below 1, using the same domain rules as the CLI and doctor.
Supplied colours must be `#RRGGBB` strings; supplied depths must be positive
integers. Null values for these keys, including unquoted colours that YAML
reads as comments, are errors. Omitted keys, empty documents, and the seeded
`--show-defaults` sample still use defaults.

Failures identify the config path, key, and expected value before source
scanning, type-checking, caching, or output in both normal and skip mode.
Validation also applies when a CLI flag would override the invalid setting.
Previously bad colours could render as black and non-positive depths could
silently disable filtering. Valid configurations keep their existing output;
the wire and cache formats are unchanged.

CI regressions under Agda 2.8 and 2.9 cover invalid values and types, quoted
mixed-case colours, depth boundaries, CLI parity and overrides, seeded configs,
doctor's multiple-error reporting, and preservation of existing caches and
outputs when validation fails.

## 2026-10-01 — `agda-deps` — complete library resolution or normal fallback

`--resolve-deps` now uses Agda's project/library parser, registry discovery,
and dependency resolver. Unversioned names prefer an exact unversioned entry,
otherwise the highest numeric installed version; versioned names require that
version. Distinct entries with the same matching name remain ambiguous.
Version-specific registries and `--library-file` follow Agda's own precedence.

The complete transitive closure must resolve before any include paths are
injected. A missing or ambiguous dependency, malformed project/library file,
or registry read failure warns and leaves Agda's arguments unchanged. The old
resolver skipped unresolved dependencies and could disable Agda's normal
library handling with only the successfully resolved siblings. Successful
pins now retain the project's own include paths, which `--no-libraries` also
disables implicitly.

Incremental fragment fingerprints now include Agda's effective include paths.
Switching library versions with byte-identical source files refreshes cached
QName source locations, even when interface hashes are unchanged. Existing
fragments are invalidated; the payload and JSON formats are unchanged, and
the main module still requires a cold check to seed its fragment.

Temporary-project regressions cover both normal and skip modes under Agda
2.8 and 2.9: version matching, the `prettyprint` / `standard-library` pattern,
atomic fallback, ambiguity, parsing, cycles, registry selection, and
incremental version changes.

## 2026-10-01 — `agda-deps` — shared startup argument parsing

Startup now recognises argv using the backend and Agda option tables before
making discovery, config, routing, or source-scan decisions. Attached short
forms (`-oDIR`, `-iDIR`, `-lLIB`) follow the same rules as separated values.
Option operands remain values even when they resemble flags or source files;
`--` preserves the positional boundary and unknown Agda flags are forwarded.
Normal and skip mode share resolved options and the identified entry source.

Relative CLI paths, including `--config`, and relative `$AGDA_DEPS_CONFIG`
paths resolve from the invocation directory before changing to the project
root. Automatic dotfile discovery still uses the settled working directory.
A missing `--config` operand now reports GetOpt's syntax error in normal,
skip, and doctor modes. Output-format inference uses the last CLI output
destination; explicit `--format` retains precedence over inference and YAML.

GetOpt parity tests and temporary-project regressions run under both supported
Agda versions. JSON fields and cache formats are unchanged.

## 2026-10-01 — `agda-deps` — project containment follows resolved paths

External classification now compares complete directory components of the
canonical project root and source paths. A sibling such as `/work/project-old`
is external to `/work/project`. Symlinks pointing outside the root are external;
aliases resolving inside are internal. Missing or unresolvable source files
are external. Both normal and skip mode share this policy; emitted source path
strings keep their existing spelling.

Each distinct source path is resolved once per run. The incremental output token
invalidates previous outputs once and tracks containment of scanned and cached
reference paths, so retargeting an unchanged source across the boundary forces
emission while preserving fragment reuse. The wire and fragment formats stay
unchanged.

Regressions cover sibling prefixes, relative paths, `..`, file and directory
symlinks, broken links, normal/skip classification, external filtering, and
incremental symlink retargeting on both supported Agda versions.

---

## 2026-10-01 — `agda-deps` — skip mode filters external file metadata

`--skip-agda --no-externals` now filters the module-to-source map and source
file inventory along with modules and import edges. Expanded `moduleFiles`
contains only retained modules, and expanded `sourceFiles` and packed `files`
omit external source paths, including files without a parseable module header.
In-project files without a module header remain in the inventory.

CI checks expanded, packed and lazy output against a temporary project and
external library, including the default run that retains externals. The wire
shape and cache formats are unchanged; skip mode does not use the caches.

---

## 2026-10-01 — `agda-deps` — lazy packed analytical fields preserved

`--json-mode=packed --lazy --packed-analytical` now writes each module's local
`kinds`, `lines`, `access`, `unsafe`, `unsolvedMetas`, optional `types`, and
optional `subterm*` arrays inside the detail file's existing `defs` object.
Previously the lazy split removed the monolithic `defs` object and silently
dropped every requested analytical field.

The detail extension is additive and optional, so the wire stays at v2 and old
lazy consumers continue to work. The monolithic and lazy forms share one data
builder and encoder; CI decodes both and compares them node-for-node with a
cold expanded graph. Default lazy output remains byte-identical.

---

## 2026-09-29 — `agda-deps` — shorter `--help`

`--help` now prints one line per flag, grouped by purpose, followed by a
pointer to the README. It is 42 lines at most 80 columns wide, down from 128,
and is identical on Agda 2.8 and 2.9. The two warnings it used to carry (the
`[SafeFlagPragma]` clash with `--lenient-imports`, and when to use
`--resolve-deps`) are now in the README's flag list.

---

## 2026-09-29 — `agda-deps` — six fixes from the pre-release review

**Config keys that act before Agda runs now work.** `quiet`, `skip-agda`,
`keep-going` and `lenient-imports` in `.agda-deps.yml` did nothing: `Main`
decided them by scanning the raw command line. It now resolves the full option
set (defaults → config → CLI) with the backend's own flag table
(`Backend.parseBackendFlags`) and routes on that, so each key behaves exactly
as its flag. The backend is still seeded with the config alone, so repeatable
flags are not applied twice.

**`--incremental` no longer serves a stale graph after the source scan
changes.** The no-op skip's token covered options, build, and the live
module set, but not the pre-scan of the `-i` directories. Adding a module that
nothing imports recompiles nothing, so the skip fired and `sourceFiles` went
stale. The token now also covers the scan, the project root and the entry
module. The token value changes, so each existing cache re-emits once.

**`--no-externals` drops a failed external module too.** `failedModules` was
filtered by `--exclude` only, so a module outside the project root whose
type-check failed under `--keep-going` survived in `failedModules` and
`modules`. It is now dropped like any other external and listed in
`externals_summary`.

**`--skip-agda --format=dot` quotes names as DOT.** It used the JSON escaper,
so `P'` rendered as `P'`.

**`access` respects an indented `private` block.** The back-fill scan treated
a `private` block as running to the next column-0 line, so an indented block
inside a sub-module swallowed its public siblings. A block now covers only the
lines indented deeper than its `private` keyword (Agda's layout rule).
Column-0 blocks are unaffected. The scan stays a source-text heuristic: Agda
drops private names from the scope it serialises, so interfaces cannot answer
the question. New fixture: `test/Access.agda`.

**Subterm hashes name references by node key.** `TermCanon` encoded a
referenced definition, constructor or projection by raw `prettyShow`, under
which same-named `where` helpers are indistinguishable (`M._.g`). Two terms
calling different helpers hashed alike. References now use the wire node key
(`M.g@8`, `M.g@14`), so a hash names the node the graph does. Hash values
change for subterms that reference `where` or section helpers; in the bundled
corpus that is five definitions. `fragmentFormatVersion` is bumped to 12 so
cached fragments with the old values are dropped. The node-key helpers moved
to a new `AgdaDeps.NodeKey` module, shared by `Deps` and `TermCanon`.

The golden is regenerated for the new fixture and the changed hashes. CI gains
a step covering the fixes the golden cannot see. The incremental step's
edit-detect assertion (`! grep -q "skipped re-emit"`) is rewritten as
`if grep …; then exit 1`: `bash -e` ignores a negated command, so it could
never fail.

---

## 2026-09-28 — `agda-deps` — `--gzip` writes a faithful `.gz`

Under `--lazy --gzip`, each `.gz` sibling was compressed from the JSON text
with every character truncated to one byte, so any file containing a non-ASCII
name (`≡`, `∀`, …) got a `.gz` that did not decompress to its `.json`. On the
bundled `test/` corpus that was 7 of the 40 lazy files, `graph.json` among
them. `writeJsonMaybeGz` now encodes the text as UTF-8 once and writes both
files from those bytes. The `.json` files are unchanged; only the broken `.gz`
files differ.

---

## 2026-09-14 — the HTML renderer moves out

`agda-deps` was doing two unrelated jobs: producing the dependency graph, which
links Agda and runs inside the type-checker, and rendering that graph as HTML,
which needs nothing from Agda at all. The second is now
[`agda-plotter`](https://github.com/input-output-hk/agda-plotter), a sibling
repository that reads the packed `graph.json` this emits. A template edit no
longer drags an Agda rebuild.

**`--format=html` is gone**, along with `--view`, `--agda-html-dir`, the
`View` catalogue, `Backend.Html`, the fourteen templates and the `views/`
gallery. The flow is two commands:

```sh
agda-deps    --format=json -i src/ -o out/ src/Main.agda
agda-plotter --view=module-dag-pods -o out/
```

**`--lazy` now applies to `--format=json`.** It was reachable only through
`--format=html`, which is what kept `buildModuleDetails` wired to the renderer.
It writes the same tree it always did — a module-level `graph.json` plus
`modules/<Module>.json` detail files — just without the page shell, which
`agda-plotter` now writes. Verified byte-for-byte against the pre-split output,
`graph.json` and every detail file. `--lazy` splits the packed form only;
`buildExpandedJson` has no such split, so `--json-mode=expanded --lazy` is inert
and now says so instead of quietly writing the wrong shape. `--gzip` follows
`--lazy` to the JSON path. `--skip-agda --format=json --lazy` works too.

`optLazy` joins `outputToken`: it now reshapes the emitted bytes, and an
output-affecting option that is missing from that fingerprint makes the
`--incremental` no-op skip serve stale output. `optView`, `optAgdaHtmlDir`,
`optWithSource`, `optNoSourceFor` and `optMaxSnippetBytes` leave it.

`lazyTreeOutput` in `Options` is the single answer to "does this run write the
lazy tree", asked by the graph emitter, the output writer, the no-op skip and
the `--skip-agda` path. It replaced two hand-copied predicates that had already
drifted: the `--skip-agda` path computed the same condition and then silently
omitted the expanded-is-inert notice the Agda path emitted. The fatal
"`--lazy` requires `-o`" check was likewise duplicated; both now live in one
`checkOutputFlags`, called from `preCompileAD` and from `--skip-agda`'s option
resolution — the earliest each path has resolved options. On the Agda path that
is still after type-checking (Agda's `GetOpt` walks argv inside the backend, so
nothing earlier sees a resolved `Options`), but it is before the per-definition
walk, the layout pass and graph assembly, instead of at the very end.

`hoistedMonoSkip` keys on `lazyTreeOutput` rather than `optLazy`, so
`--lazy --json-mode=expanded` — which does write one monolithic file — gets the
up-front skip too. And `graph.json` now takes that same skip against its own
manifest slot: the skeleton is *not* small, because `--lazy` moves out only the
`defs`/`edges` blobs and leaves `searchIndex` (every definition name plus its
bigrams) behind — measured at ~630 bytes per module, so tens of megabytes of
`String` re-materialised on every no-op rebuild of a corpus big enough to want
`--lazy`. On an unchanged rebuild its thunk is never forced at all.

**`--with-source` was dropped, not moved.** It drove Agda's HTML highlighter
over every loaded module from a live `TCM` session with visited interfaces, and
sliced each definition's highlighted span into `snippets/<Module>.json`. A
renderer reading a file on disk has none of that. Removing it takes
`AgdaDeps.Source`, `--no-source-for`, `--max-snippet-bytes`, the `giWithSource`
/ `giSnippetModules` inputs and the `bundleFiles` field with it — and, because
the snippet-bundle code held the renderer's only imports of `Agda.Utils.Hash`,
`AgdaDeps.Deps` and `AgdaDeps.Source`, that removal is precisely what lets
`agda-plotter` link no Agda. `--agda-html-dir` survives in the plotter as the
link-out path to `agda --html` pages. The Agda-free route back to inline
snippets — slicing those same pages using the source locations the graph
already carries — is recorded in the plotter's backlog.

**The palette is duplicated, not moved.** DOT still needs the four state
colours, so `--theme` and `--color-*` stay here and `agda-plotter` carries its
own copy with the same names, defaults and presets. Nothing puts them on the
wire; change one, change both.

**The expanded wire format did not change.** The cold golden, the generated
schema, and the packed-analytical parity check are all unchanged — this moved a
renderer, not a field. Two dead things went with it: a `"::mono::"` manifest
slot `SerialiseCache` documented but no code ever wrote or read, and
`gjoModuleNames`, which had no consumer anywhere.

The docs site drops the view gallery and grows a "what reads the graph" section
pointing at `agda-plotter` and `agda-graph-explorer`. `Backlog.md` and
`Changelog.md` move from `INTERNAL_PAGES` to `DOC_PAGES`, where they belonged:
both are published and tracked under `docs/`, so staging them only under
`--internal` meant a plain `make html` left them stale while the rest of the
site moved on.

---

## 2026-09-04 — `agda-deps` — `argUsage`, first field report from a consumer

`agda-unused` ran the `arg-removable` / `arg-erasable` checks over a real proof
development (Jolteon/FastBFT, 6,185 defs) and reviewed every `arg-removable`
finding against source. No verdict was wrong — but acting on one class of them
broke the build, and most of the rest were unactionable for want of context.
Six changes, one of them a soundness fix.

**Soundness: a removal must not orphan an earlier hidden binder.**
`guardDeletable` asked only whether the removed position's *own* variable
survived. A hidden or instance binder is supplied by inference, which needs
somewhere to read it from: `typeOf : {A : Set} → A → Set` has a genuinely
unused value argument whose domain is `{A}`'s only occurrence, so deleting it
leaves `{A}` unsolvable at every call site. `Deps.orphanedHidden` joins
`deletableRemovable`'s fixpoint as a second rule — a hidden binder not itself
being removed, whose every occurrence sits inside a removed domain, rejects all
of those removals. Both spines vote and the reduced one decides, since
solvability is settled by a unifier that reduces. Cost zero findings on
`test/`.

**`syntacticArity`, and a docs fix.** The index space was documented as "the
definition's own binders — the ones on its signature line". It is the own
*reduced* telescope, which can be **longer**: a type whose codomain only becomes
a function after unfolding contributes positions with no written binder
(`noop : (A : Set) → Tracer A` reports arity 4 off one binder) — enough to
produce two confident false-positive reports downstream. Such positions are
worth keeping, so they are now *labelled* rather than dropped:
`syntacticArity` gives the boundary, omitted when it equals `arity`. Every
`binders` key is below it (asserted in `Wire.validateExpanded`), so an absent
entry means "past the signature line" and a present entry with no `name` means
"written, spelled `_`". README, `CLAUDE.md` and the schema description are
corrected.

**`binders[].type`** (under `--with-signatures`) — each reported binder's domain,
reified in the context of the binders before it. Most reported positions have no
binder name at all, leaving "argument 5 of 11" as the whole report line. Never
normalised: reducing a domain destroys the head symbol that makes it
recognisable.

**`occursInBody`** — the `removable` positions whose variable the elaborated body
still mentions, i.e. the value is threaded into a callee that discards it, so the
deletion has to reach that callee too. A `removable` position *absent* from it is
a purely local edit. This also answers the "resolved-instance" false positive: an
instance argument that never appears in the source body but which instance search
resolves from is a body occurrence at an instance position — pair it with
`binders[i].hiding`.

**`partiallyApplied`** — `true` when the definition is referenced somewhere in the
graph with fewer arguments than it takes. Used as a value, its arity is its
interface and no position is really removable, whatever the polarity says
(`EagerlyAfterT t = Eager ∩¹ AfterT t`). The one `argUsage` field the producer
cannot compute per-definition: `Deps.unsaturatedTargets` measures the sites, a
new per-source side channel carries them, and `postCompileAD` back-fills the
flag alongside the other whole-corpus rollups. Arity for the test rides on
`NodeRef` (`nrArity`), off the single `getConstInfo` `mkRef` already pays.

**`moduleEffectiveOptions`** (top-level) — the actionability-relevant options
actually in force per module, currently `--erasure` alone, read from
`iOptionsUsed`. Without `--erasure` the `@0` that every `erasable` verdict
suggests is `[AttributeKindNotEnabled]`, so those verdicts are un-appliable
however true they are, with nothing on the wire to say so.

Not done: reporting `name: null` for an *inserted* instance binder whose source
says `_`. The plain case is already handled (a written `⦃ _ : T ⦄` reports no
`name`), and neither `Origin` field separates written from inserted — a written
`⦃ d : T ⦄` also reports `Inserted`. The one live lead is a `domName`/`Abs`-name
disagreement, unverifiable without a reproduction. Logged in
[Backlog.md](Backlog.md).

No `v` / `nodeKeyVersion` bump: every addition is optional and omitted when it
has nothing to say, so a corpus with no findings stays byte-identical. Fragment
cache format v10 → v11. Identical Agda API on 2.8 and 2.9 (no CPP), and both
emit the same graph. Fixtures:
`ArgUsage.{typeOf,solvableElsewhere,explicitStaysPassed,konst,konstSaturated,viaInstance,useless2,SecTyped.typed}`.

---

## 2026-08-31 — `agda-deps` — `removable` no longer claims undeletable binders

Soundness fix in `argUsage`. `Unused` + `Nonvariant` is Agda's answer to "does
the definition's meaning depend on this value" — not to "can this binder be
deleted", which is what `removable` claims. The two come apart when the argument
occurs in the type only at an **irrelevant** position: `dependentPolarity` tests
occurrence with `relevantInIgnoringSortAnn`, whose `RelevantIn` monoid discards
occurrences under irrelevance, so the position is never demoted to `Invariant`
and `defArgOccurrences` does not count it either. Deleting the binder then leaves
the type naming something out of scope.

`Deps.guardDeletable` now filters `removable`: a position is dropped when its
variable is free in the codomain, or in the domain of a later argument that is
*not itself being removed*. That is Agda's own `relevantInIgnoringNonvariant`
condition re-run with relevance-blind `freeIn`. The exemption for other
surviving-removable domains is what keeps jointly-removable chains
(`removableRequires`) intact, and the filter iterates to a fixpoint because
rejecting one position can strand an earlier one.

Three shapes, all present in the standard library: an irrelevant binder (42
defs); a **relevant** binder whose only occurrence is at a callee's irrelevant
argument position (5) — invisible to any test on the binder itself, so no
consumer-side filter could have substituted; and an occurrence **hidden by
reduction** (20), where e.g. `U : {a} {A : Set a} → Pred A 0ℓ` has `A` in its
codomain as written, but `Pred A 0ℓ` reduces to `A → Set` and the occurrence
lands in the domain of a later unused (`Nonvariant`) argument — exactly what
Agda's rule is meant to discount. The last class is why relevance-blindness alone
is not enough.

Occurrence is now judged on the syntactic `Pi` spine *and* the reduced one,
because neither alone is sound: `telView` reduces, which can erase an occurrence
the source still has (`Irrel n p` ⇝ `Wrap n`), while the syntactic spine stops at
a type that only becomes a function after unfolding. Either view may veto.

Measured on agda-stdlib 2.4: `removable` findings 145 → **98** defs, 244 → **142**
positions (47 defs lost every finding, 20 lost some), 0 defs gained anything.
`erasable` is untouched by design — 5,463 defs / 18,992 positions before and
after. No measurable cost (whole-stdlib wall clock 30.8s, within run-to-run
noise of the 30.0–30.6s baselines).

Wire shape unchanged: no schema edit, no `fragmentFormatVersion` bump, no flag.
Consumers that already decode `argUsage` need no change; they simply stop seeing
the false positives. Reported by the `agda-graph-explorer` consumer repo, which
also independently reproduced the round-2 corpus counts exactly (20,384 defs /
2,275 modules / 5,521 with `argUsage` / 145 `removable`), closing the discrepancy
flagged in round 2.

## 2026-08-31 — `agda-deps` — match-constant: measured, not shipped

New module `AgdaDeps.MatchConstant`, and deliberately **not** a wire field.
It finds *match-constant* positions — arguments whose case split could be
replaced by a wildcard — off the compiled case tree (`funCompiled`), which
never reaches the wire. Runs only under `AGDA_DEPS_MATCH_CONSTANT=1`, where it
dumps `MC-CAND` / `MC-HIT` lines to stderr; `graph.json` is byte-identical
either way.

Requested measure-first by the `agda-graph-explorer` consumer repo, and the
measurement says no: **1 sound finding in 15,298 stdlib functions with a case
tree, 0 in 6,795 from an implementation-heavy corpus** — and the one finding is
`Data.Unit.NonEta.hide`, whose stuck match on non-eta `unit` is the whole point
of the definition. Phase 1's `removable` finds 145 in the same population.

The interesting part is why the raw number was 102 before it was 1: the
specified property ("every branch computes the same thing") compares branch
*bodies*, and in a dependently typed language a match also refines the
branches' *types*. `not-involutive true = refl; not-involutive false = refl`
has one identical body and does not survive wildcarding. That shape was 101 of
the 102 candidates. Reporting now also requires the split variable to be free
in neither a later domain nor the codomain — a plain occurrence check, so every
branch shares one goal type.

Also: the analysis reports a position only when *every* split on it in the
tree is collapsible, not just the one at the root — one argument can be split
in several subtrees and wildcarding removes them all at once.

Kept as a probe so the yield can be re-measured, pinned by
`test-matchconstant/` (5 findings, 7 controls) and a CI step, with the rationale
in [Backlog.md](Backlog.md). No wire field, no schema change, no
`fragmentFormatVersion` bump. 2.9's `Done` is a pattern synonym over `CCDone`
with two extra fields, bridged by `Util.ccDone` so the new module needs no CPP.

## 2026-08-31 — `agda-deps` — the `with` edge-provenance tag is gone

`definitionEdgesProvenance` had five values; one of them could never appear.
`with` was emitted when a dependency equalled the source definition's `funWith`,
but `funWith` names a with-function's *parent* and is non-empty on **exactly** the
definitions `ignoreDef` drops — so the branch could only be reached while walking a
definition that is never emitted, and then only for a *recursive* `with` (the
helper has to reference its parent). `contractIgnoredEdges` discards inside-chain
provenance on top of that.

Measured on a probe with a nested `with` and a recursive `with`, on Agda 2.8 and
2.9: zero `with` edges, and the parent's dependency on a name mentioned only inside
a with-branch arrives tagged `body`. Removing the value changed no emitted byte —
the committed golden was unaffected.

Gone with it: the `EWith` constructor, `tagOneWith`'s `withTarget` parameter, and
`Util.isWithFun'` (its only caller). The numeric slot `3` in `encodeEdgeProv` and
`Binary EdgeProv` is left as a hole so the packed encoding of the surviving tags
does not shift. Recovering a *meaningful* with signal would mean tagging at
contraction time — a wire-content change, logged in [Backlog.md](Backlog.md).

Fragment cache format v9 → v10: a v9 fragment for a module with a recursive `with`
can contain the retired tag byte, and a fragment that fails to decode is a silent
miss — for a warm main module, one that never heals (it is not re-cached). The
header bump makes every stale fragment miss once, predictably.

Reported by the `agda-graph-explorer` consumer repo, which had gone looking for
"unnecessary `with`-abstraction" and found the tag instead.

## 2026-08-31 — `agda-deps` — never-used arguments (`argUsage`)

Expanded `graph.json` reports arguments a definition never uses. Additive: no
`v` bump, no `nodeKeyVersion` bump, no flag.

- **Per-def `argUsage`** (expanded only) —
  `{removable: [i…], removableRequires: {…}, erasable: [i…], arity: n}`.
  `removable` = the binder and every call-site argument can go; `erasable` =
  used only in types, an `@0` candidate rather than a removal. Omitted when
  there is nothing to report.
- **`removableRequires`** maps a position to the others that must be removed
  with it, transitively; omitted when every removal stands alone. Some
  multi-position removals are valid only as a set, others are independent,
  and the relation is directed rather than a partition.
- **`binders`** says how each *reported* position is written —
  `{"0": {"hiding": "implicit", "name": "a"}}`, keyed like
  `removableRequires`, sparse. Without it "argument 0" of
  `{a : Set} → List a → List a` reads as the first `List` to almost anyone,
  and it is the `{a : Set}`; on the standard library only 69 of 244
  `removable` positions are `explicit`. Read off the syntactic `Pi` spine, so
  `hiding` is always there, `name` only when the binder has one, and a
  position the spine does not reach gets no entry rather than a guess. Costs
  nothing measurable: the walk *replaces* the `arity` count the same code
  already paid (whole-stdlib wall clock 30.0s vs 30.5s before, two runs each).

Read off `defArgOccurrences` + `defPolarity`, which Agda fills in for every
mutual block during positivity/polarity checking and serialises into the
interface. So the verdict is interprocedural — an argument passed to a helper
that discards it reads unused in the caller — and type-dependency aware.

Indices are the definition's **own** binders. Agda prepends the enclosing
section's telescope to every definition inside it, so the raw verdict is
shifted down by `lookupSection`'s size and anything in that prefix dropped;
otherwise a `where` helper reports its parent's binders. The sibling `type`
string is *not* shifted, so indices do not index it.

Scope: non-projection-like functions only (`droppedPars == 0`). Projections
and constructors drop parameters from both lists, shifting their indices;
`Axiom`/`Primitive` have no body; for `Datatype`/`Record` `enablePhantomTypes`
purges `Nonvariant` parameters.

Also fixed: under `--keep-going`, `mergeIfaceSig` merged only `sigDefinitions`
out of the interface's `Signature`. Since `lookupSection` falls back to
`EmptyTel` rather than failing, section telescopes silently read as empty —
and `sigRewriteRules` / `sigInstances` were empty too. Now delegates to Agda's
`unionSignature`, which merges all four fields with the right per-field
semantics.

`binders` is re-indexed with the verdict it annotates, so a `where` helper
reports its own binder name and not the parent's. A name containing a `.`
(`A.a`) is a binder Agda inserted by generalising a `variable` declaration and
is passed through as Agda's own printer spells it — a written binder name can
never contain `.`, so it doubles as the signal that the position has nothing on
the signature line to edit.

Fragment cache format v7 → v9 (`ADDef` gained `_argUsage`; `ArgUsage` gained
`auBinders`).

Two Agda 2.9 fixes found while verifying the above against the opt-in 2.9 job,
which had gone red: `Monad.Signature` no longer exports `unionSignature` (its
successor `importSignature` is private to `Interaction.Imports`), so 2.9 gets a
CPP-gated local mirror over the whole `Sig` record; and `test/ArgUsage.agda`'s
`Vec` was indexed by `Nat`, whose constructors `test/RenamedReexport.agda`
re-exports — `--with-signatures` then reified `suc` as `Nat.suc` on 2.8 and
`RenamedReexport.suc` on 2.9, so the golden was reproducible on 2.8 only. The
fixture now indexes `Vec` by a local `Idx`. 2.8/2.9 golden parity is green
again.

## 2026-08-13 — `agda-deps` — silent unsolved metas are first-class

Under `--allow-unsolved-metas` / `--lenient-imports`, a module with unsolved
metavariables *succeeds* (Agda postulates them as `unsolved#meta.*`), so
`failedModules: []` never meant "everything compiles" — and the graph
conflated an honest interaction `?` with a silently-inserted unsolved meta
(missing record field, failed instance search, unsolved `_`), the exact error
class plain `agda` rejects with `[UnsolvedMetaVariables]`. Both now surface,
additively (no `v` bump, no `nodeKeyVersion` bump, no new flag):

- **Per-def `unsolvedMetas`** (expanded; packed-analytical `Int32` array) —
  count of silent unsolved metas the def mentions directly. Honest `?`s are
  *not* counted: `H` with no count = open goal(s) only; `H` with a count =
  silently-missing evidence. Omitted when 0.
- **Top-level `unsolvedModules`** (packed / expanded / lazy) — module →
  `{metas: [lines], constraints: [lines]}`. One `metas` entry per silent meta
  (exact — from the markers / live meta store, not highlighting spans);
  `constraints` lines are best-effort from `UnsolvedConstraint` spans.
  Omitted when empty, so unsolved-free corpora stay byte-identical.

The split is Agda's own: `warningHighlighting` stamps `UnsolvedMetaVariables`
ranges with the `UnsolvedMeta` aspect into `iHighlighting` *before*
`openMetasToPostulates`, and `UnsolvedInteractionMetas` get nothing — so an
imported module's marker is silent iff its binding site lands in such a span,
and the main module (whose metas are never postulated) reads live open metas
minus interaction points. Identical API on Agda 2.8/2.9; no CPP.

Also: fragment cache format v6 → v7 (`ADDef` gained `_unsolvedMetas`), the
JSON Schema + oracle gained `unsolvedMetas` / `unsolvedModules` /
`$defs/unsolvedModule`, `schema/packed_analytical_check.py` now checks the
new array, and a `test-unsolved/` fixture corpus (the `record { go }`
missing-field repro plus an honest `?`) locks the split in CI.

## 2026-08-11 — `agda-deps` — `agda-deps doctor` checks the config file

New subcommand — the first one; everything else is a flag:

```
agda-deps doctor [--config=PATH] [--strict]
```

It resolves the config the way a real run does (`--config=PATH`,
`$AGDA_DEPS_CONFIG`, `./.agda-deps.yml`, then the dotfile beside the nearest
`*.agda-lib`), reports the file and how it was found, and checks it — with no
Agda run and no input module. The three classes of finding are exactly the ones
a config gets wrong *silently*:

- **unknown keys** — `FromJSON Config` reads with `.:?`, so a misspelled key is
  ignored and the setting simply never applies. Reported with a did-you-mean
  (Levenshtein over the real key set).
- **bad values** — type (`exclude: Data` where a list is required, a quoted
  `"true"`), enum (an unrecognised `view:` slug, with a did-you-mean), and
  domain (a colour that isn't `#RRGGBB`, a negative `max-snippet-bytes`, a
  `min-term-depth` below 1 — both of which the YAML path otherwise drops
  without a word). Includes the YAML trap of an unquoted
  `color-hole: #9c27b0`, where `#` opens a comment and the key lands as null.
- **incoherent combinations** — `with-source` without `lazy`, `cache-dir`
  without `incremental`, `min-term-depth` without `with-term-hashes`,
  `normalise-signatures` / `signature-implicits` without `with-signatures`,
  `incremental` with `keep-going`, per-definition flags under `skip-agda`, a
  `view:` / `json-mode:` / `gzip:` that the chosen `format` never consults, and
  an `out-dir` whose `.json` / `.html` extension will *not* select the format
  (that inference only fires for `-o` on the command line).

Exit status is 1 on any error, 0 otherwise; `--strict` fails on warnings too,
so it can gate CI. Warnings judge the config alone — a CLI flag layered on top
can rescue any of them.

Supporting changes:

- **`Options.allViews` / `allFormats` / `allJsonModes` / `parseSlug`** and
  **`Config.allThemes` / `themeSlug`**: the accepted slugs of each enum setting
  now live in one table per type, and the CLI parser, the YAML parser, and
  `doctor` all read it. Previously `--view`'s accepted set was spelled out
  three times (parser, `FromJSON View`, error message); `doctor` telling the
  user a value is invalid that the parser accepts (or vice versa) is now
  unrepresentable.
- **`Config.findConfigPath`** exposes discovery with provenance
  (`ConfigOrigin`); `discoverConfigPath` is a thin wrapper that keeps the
  old `die`-on-missing-file behaviour. One search order, not two.
- `schema/show_defaults_check.py` takes an optional third argument and now
  guards *both* mirrors of the config key set (the `--show-defaults` sample and
  `Doctor.knownFields`) against `FromJSON Config`. CI passes `Doctor.hs` and
  additionally runs `doctor` over the seeded sample, over a fully uncommented
  copy of it, and over a file with a misspelled key (which must exit 1).

## 2026-07-22 — `agda-deps` — `--show-defaults` seeds a config file

New intercept flag, alongside `--help` / `--version` / `--emit-schema`:

- **`--show-defaults`** prints a commented sample `.agda-deps.yml` — every
  YAML key with its built-in default value and a one-line description, all
  commented out — then exits. Seed a project config with
  `agda-deps --show-defaults > .agda-deps.yml`, then uncomment and edit only
  the keys you want to override.

The sample text lives in `Config.showDefaultsYaml`, reading the printed
defaults from `defaultOptions` / `defaultPalette` so they can't drift; the key
names are kept in lock-step with the `FromJSON Config` instance (a build-time
guarantee both are the same 30 keys). Because a comment-only file decodes to
YAML `Null`, `FromJSON Config` now treats a `Null` (empty / comment-only)
document as an empty config, so a freshly-seeded file reproduces the defaults
verbatim before anything is uncommented.

## 2026-07-16 — `agda-deps` — filter `variable`-block names on Agda 2.8 too

`ignoreDef` dropped Agda's synthesised `variable`-block definitions
(`GeneralizeTel` record, `mkGeneralizeTel` constructor, `generalizedField-*`
projections) by testing for the `NoName` `..` marker in `prettyShow`. Agda 2.9
qualifies all of them with that marker, but **2.8 names the record and
constructor without it** (only the field projections keep it), so on 2.8 two
extra nodes (`Test.GeneralizeTel` / `Test.mkGeneralizeTel`) leaked into the
graph — the sole remaining 2.8-vs-2.9 output divergence.

- **`isGeneralizeName`** now matches the stable generated base name on
  `qnameName` (`GeneralizeTel` / `generalizedField-`) in addition to the `..`
  marker, catching both spellings. Agda 2.8 and 2.9 now produce byte-identical
  graphs (verified: both match the golden). Pinned by `test/Test.agda`'s
  `variable a b : Set` block.

## 2026-07-16 — `agda-deps` — `--incremental` works on Agda 2.8; node identity is `NodeRef`

The `--incremental` fragment cache was Agda ≥ 2.9 only: it serialised
`QName`s through Agda's `EmbPrj`, whose byte layer 2.8 does not expose, so
on 2.8 the flag warned and ran without the fragment cache.

Root cause removed by making node identity a **`NodeRef`** — a precomputed,
`Data.Binary`-serialisable bundle (`nodeKey` string, hash, `moduleKey`,
binding line/file, `prettyShow`, and a precomputed `ignoreDef` flag). Every
downstream pass already consumed the `QName` only through pure projections
(`nodeKey` / `moduleKey` / `srcLocOf` / `bindingLine`); the one exception was
`contractIgnoredEdges`, whose `ignoreDependency` (`getConstInfo`) is now
folded into `NodeRef.nrIgnorable` at the producer boundary (`mkRef`). So no
pass needs a live `QName`, and a cached fragment round-trips as plain data.

- **Fragment cache works on 2.8 and 2.9 alike** — serialisation is plain
  `Data.Binary`; the `EmbPrj` wire form and the `FragmentCache` CPP split
  are gone. `fragmentFormatVersion` bumped 3 → 4.
- **`ADDef`, `IgnoredEdgeMap`, `MethodProviderMap` are keyed by `NodeRef`.**
  The `...OfQ` helpers (`nodeKeyOfQ` / `moduleKeyOfQ`) hold the QName-level
  logic, used only at the producer boundary (dead-private recovery,
  `collectReExports`).
- **Output unchanged.** Byte-identical `graph.json` on 2.9 (golden + schema
  + packed-analytical parity) and identical to the pre-change 2.8 output;
  cold- and warm-cache runs remain byte-identical. `nodeKeyVersion` is
  unchanged (3) — the node-key *string* convention did not move.

## 2026-07-10 — `agda-deps` — tag file-level `{-# OPTIONS #-}` soundness escapes (R15)

Soundness-escape Phase 2, completing the Phase 1 per-def `unsafe` work
(2026-07-09). Phase 1 covered per-def escapes (`NON_TERMINATING`,
`primTrustMe`), but a *whole-module* escape via a file pragma
(`{-# OPTIONS --type-in-type #-}`, `--no-positivity-check`, `--rewriting`,
…) left every def in the module as plain `state: "D"`, so a graph-derived
`agda --safe` audit still missed it.

- **New optional top-level `moduleOptionEscapes`** — a `Map module
  [String]` (object keyed by module name; values the offending flag
  tokens). Read from each visited interface's **`iFilePragmaOptions`** —
  the file's own `OPTIONS` tokens — in `postCompileAD`, keeping only the
  safety-relevant flags (`AgdaDeps.Deps.safetyRelevantOptionFlags`, the
  unconditional single-flag set of Agda's own `unsafePragmaOptions`).
- **File-level, not resolved.** Deliberately `iFilePragmaOptions` and NOT
  `iOptionsUsed` (the fully-resolved per-module options): `iOptionsUsed`
  folds in command-line + library-default options, so it would
  misattribute e.g. `--lenient-imports` (⇒ `--allow-unsolved-metas`) or a
  library `.agda-lib` default to *every* module. The file scan is
  pollution-immune and exactly "what this file declared".
- **Boundary (verified, documented).** A per-block `{-# NO_POSITIVITY_CHECK #-}`
  is a *declaration* pragma, not an `OPTIONS` pragma, so it never appears in
  `iFilePragmaOptions` and is not captured; nor are combination-conditional
  escapes (`--without-K` + `--flat-split`, …). Pinned by
  `test/OptionEscapes.agda`, whose file-level `--type-in-type` surfaces
  while its block `NO_POSITIVITY_CHECK` does not.
- Emitted in expanded + packed + lazy `graph.json`, module-level (orthogonal
  to per-def `unsafe`), omitted when empty so escape-free corpora stay
  byte-identical. Additive wire field: `schemaVersion` stays 2,
  `nodeKeyVersion` stays 3. Schema oracle updated from `Wire.hs`; golden
  regenerated cold (`Holes`/`Test` carry their real `--allow-unsolved-metas`,
  `OptionEscapes` its `--type-in-type`). No `--incremental` fragment bump:
  escapes are recomputed from the visited interfaces every run, not cached.
- Both Agda 2.8 and 2.9 builds compile unchanged — `iFilePragmaOptions` /
  `OptionsPragma` are identical across the range, so no CPP.

## 2026-07-09 — `agda-deps` — tag soundness escapes beyond postulates (`unsafe`)

Acting on external feedback: the graph flags postulates (`state: "P"`) and
unsolved holes (`"H"`), but a `{-# NON_TERMINATING #-}` function or a body
built on `primTrustMe` emitted as plain `state: "D"` — indistinguishable
from safe code, so a graph-derived `agda --safe`-style audit missed them.

- **New optional per-def `unsafe` array** — the escapes a definition uses
  **directly** (not transitively): `non-terminating` (a
  `{-# NON_TERMINATING #-}` function, `funTerminates = Just False`) and
  `trustme` (the body/type references `primTrustMe`). Orthogonal to
  `state`: a def can be `D` and still carry an escape. Always computed (no
  flag; the signals are already in hand during the per-def walk), omitted
  when empty, so escape-free corpora produce byte-identical output.
- **Packed-analytical parity:** a dense `unsafe` `Int8` bitmask array
  (bit 0 = `non-terminating`, bit 1 = `trustme`; `0` = none), so a decoded
  packed graph stays node-for-node identical to expanded
  (`schema/packed_analytical_check.py` extended to decode + compare it).
- **`{-# TERMINATING #-}` was deliberately dropped.** Verified against the
  corpus that Agda's ordinary termination checker also writes
  `funTerminates = Just True` for every proven-terminating def, so the
  marker can't be told apart from a normal proof — it would fire on
  `Nat._+_`, `Test.sum`, and friends. `non-terminating` alone fixes the
  measured audit miss.
- Additive wire field: `schemaVersion` stays 2, `nodeKeyVersion` stays 3.
  Schema oracle regenerated from `Wire.hs`; golden regenerated cold.
  `--incremental` fragment format bumped 2 → 3 (tags ride the fragment, so
  a `Skip`ped module keeps them; older caches self-invalidate).
- Fixture: `test/Unsafe.agda` (`NON_TERMINATING`, `primTrustMe`, a
  `TERMINATING` control, and a plain function that must carry no tag).

## 2026-07-09 — `agda-deps` — emit `renaming` aliases on public re-exports

Acting on external feedback: `open import M public renaming (merge to
combine)` re-exports `M.merge` under the in-scope name `combine`, but the
expanded `graph.json` `reexports[]` rows carried canonical FQNs only, so a
consumer could not resolve `combine` back to `M.merge`. The alias was
already computed in `collectReExports` and discarded.

- **New optional `renames` map** on each expanded-mode `reexport` object:
  `{ alias-in-scope-name: canonical-nodeKey }`, where the canonical value
  is a member of that row's `names`. Omitted when the row has no renamed
  entries, so rename-free corpora produce byte-identical output.
- Expanded-only — packed and `--lazy` never emitted `reexports`, so there
  is no packed-analytical or lazy work, and no fragment-format bump
  (re-exports are derived in `postCompile`, not cached).
- Additive wire field: `schemaVersion` stays 2, `nodeKeyVersion` stays 3.
  Schema oracle regenerated from `Wire.hs`; golden regenerated cold.
- Fixture: `test/RenamedReexport.agda`
  (`open import Nat public renaming (Nat to Number)`).

## 2026-06-30 — `agda-deps` — fix: `wiki-backlinks` view back/forward navigation

The `wiki-backlinks` view named its navigation stack `history`, which
at global script scope aliases the read-only `window.history` — so the
first `navigate(…, push)` threw `history.slice is not a function` and
broke back/forward. Renamed the stack to `navHistory`. HTML-only.

## 2026-06-30 — `agda-deps` — lift anonymous-module definitions into their parent (nodeKeyVersion 3)

Fixes the anonymous-module blind spot: defs inside `where` blocks and
`module _ (…) where` sections produced false module-level and provenance
results. Agda desugars both into anonymous sub-modules (`Mod._`) and
lifts enclosing variables into each def's `defType`, so the dependency
edges were already correct — only naming/attribution/provenance was wrong.

- **`nodeKey` lifts anonymous segments** (`liftAnonSegments`):
  `Mod._.helper@15` ↦ `Mod.helper@15`, `Mod._._.deep` ↦ `Mod.deep`.
  The `@<line>` disambiguator is preserved; mixfix names (`_+_`) are
  untouched. `nodeKeyVersion` bumped 2 → 3.
- **`moduleKey`** re-homes module attribution to the nearest *named*
  ancestor; every QName→module-string site routes through it, killing
  phantom `Mod._` nodes and their false `Mod ⇄ Mod._` cycles.
- **Provenance `where` → `module-local`**: the tag describes the target
  (an anonymous-module-local helper) rather than claiming an
  unrecoverable source-ownership relation. Packed int encoding unchanged
  (still `2`); expanded string + schema enum updated.

`where` and section are represented identically post-scope-check, so
they are not distinguished. Cold golden regenerated. New regression
`test/AnonSection.agda`; `test/Collision.agda` still locks the `where` case.

## 2026-06-18 — `agda-deps` — rebuild-memory reductions

Memory pass on the producer's rebuild path. The dominant peak-RSS term
is Agda's own interface-load floor (irreducible in a whole-program
backend); of the removable remainder, copying-GC slack was the largest.
Output is byte-identical.

- **`-rtsopts -with-rtsopts=-F1.2`** (`agda-deps.cabal`). The binary had
  no `-rtsopts`, so `+RTS`/`GHCRTS` were ignored. `-F1.2` caps old-gen
  heap growth at 1.2× live (default 2.0×): ~11% lower peak RSS at no
  measurable wall cost, no hard ceiling. `-rtsopts` lets callers override.
- **Strict `_deps`/`_state` in `ADDef`** — the two fields that lacked
  `!`; a lazy `_state` thunk closed over the whole Agda `Definition`.
- **Force `liveModules`** (`Backend.hs`) — a lazy `[String]` pinned the
  entire `defMap` alive through the render in non-`--incremental` runs.

`--incremental` is a wall-time win, not a memory one.

## 2026-06-13 — `agda-deps` — `--packed-analytical` (consumer-usable packed form)

Packed `graph.json` is ~5× smaller than expanded but omitted every
per-definition analytical field. `--packed-analytical` adds them so
consumers no longer have to choose size or fidelity.

- **New arrays parallel to `defs.names`**: `defs.kinds` (Int8),
  `defs.lines` (Int32, `-1`=unknown), `defs.access` (Int8),
  `defs.types` (under `--with-signatures`), CSR-packed subterm
  offsets/hashes/depths (under `--with-term-hashes`). No topology change.
- **`access` is 3-valued** (`0`=unknown/absent, `1`=public,
  `2`=private): expanded *omits* `access` for QNames with no local
  `ADDef`, and `0` round-trips to that omission (`line`→`-1`, `type`→null
  likewise), so the two forms match exactly.
- **Shared per-QName lookups** guarantee parity between the expanded
  emitter and the packed arrays — don't inline them back per-form.
- Off by default; default packed output stays byte-identical. Only
  meaningful with `--json-mode=packed`. Gated by
  `schema/packed_analytical_check.py` (run both sides cold).

## 2026-06-13 — `agda-deps` — incremental serialise (P2), cache GC + `--cache-dir`, re-export-hub externals

### Incremental serialise (P2)

New `AgdaDeps.SerialiseCache` (plain-text manifest; no CPP) cuts
serialise+write on a rebuild, on top of P1's per-definition walk cut.

- **Monolithic output** (`deps.json`/inline `deps.html`) can't be
  patched cheaply, so the win is the no-op rebuild: when nothing
  recompiled (`recompiledRef`) *and* the `outputToken` (module set +
  output-affecting options + build identity + `nodeKeyVersion`) matches,
  generation and write are both skipped. Both guards are required —
  the token alone misses a recompiled body, `recompiledRef` alone misses
  a toggled rendering option.
- **Lazy per-module files** carry a content epoch computed from the
  structured inputs (no base64), so a skipped file never forces its
  content thunk. Adding/removing a def shifts global indices, so many
  epochs change (correct if not minimal).
- Profiling shows the warm-rebuild floor is Agda's interface load, which
  a backend cannot avoid; this helps signature-/source-heavy output and
  no-op rebuilds, not the floor.
- Gated on `--incremental`; default output path byte-identical.

### Fragment cache GC + `--cache-dir`

- **GC**: after an `--incremental` run, `*.frag` files for modules no
  longer in the graph are pruned (`gcFragments`); only `*.frag` touched.
- **`--cache-dir=PATH`** (CLI + YAML) overrides the default
  `<out-dir>/.agda-deps-cache` for fragments and the serialise manifest.

### `classifyExternalModules` sees re-export hubs

A stdlib module that only `open … public`s names contributes no QName of
its own and slipped past `--no-externals`. The re-export host + source
module names (`collectReExports`) are now pooled into the classification
input. Additive: golden unchanged.

## 2026-06-12 — `agda-deps` — `--keep-going` hardening: a graph is always emitted

On a real broken corpus the partial pass died with a bare exit 120 and
no `deps.json`. Root cause: exit 120 is Agda's `__IMPOSSIBLE__`, a GHC
exception (not a `TCErr`), invisible to every `catchError` guard; and
TCM's `catchError` rolls back `TCState`, so re-merging only interface
*signatures* left reification hitting a missing-builtin `__IMPOSSIBLE__`.

- **`mergeIfaceState`** now rebuilds the import state as Agda's own
  `mergeInterface` does: signature + builtins (with per-primitive
  rebinds) + remote metas + pattern synonyms + display forms.
- **`catchAllTCM`** (catches TCErr *and* GHC exceptions; re-throws
  `ExitCode`/async) guards every stage — per definition, per module, per
  interface merge; `preCompile`/`postCompile` failures print a
  stage-named diagnostic before re-throwing.
- **The partial pass no longer claims an entry module** — it passed
  `IsMain` to every module, so `entryModule` recorded whichever ran last.
- Fixture + CI step `test-keepgoing/` (kept outside `test/`): entry
  imports one healthy and one failing module; CI asserts `deps.json` is
  produced with `failedModules == ["Broken"]`.

## 2026-06-12 — `agda-deps` — `--incremental`: per-module fragment cache

P1 of the incremental-rebuild design: the dominant rebuild cost is the
per-definition backend walk, re-run for every module even when nothing
changed. `AgdaDeps.FragmentCache` caches, per module, what `postModuleAD`
returns plus the module's contributions to the two compile-time
side-channels (ignored edges, instance-method providers).

- **The slices are exact before/after deltas** snapshotted in
  `ModuleEnv` — a `Skip`ped module never runs `compileDef`, so without
  them contraction silently loses edges through its helpers. A
  name-prefix filter is wrong: it misses defs Agda homes in anonymous
  modules at prefixless QNames.
- **Key**: `(fragment format version, content-option fingerprint,
  iFullHash, nodeKeyVersion)`. `iFullHash` folds in transitive imported
  hashes, invalidating exactly the affected cone; rendering-only options
  are excluded.
- **Flow**: `moduleSetup` returns `Skip` on a hit. `postModuleAD` writes
  imported modules unconditionally, the **main module only from a fresh
  check** (its output is enriched by the `getSignature` dead-private
  recovery a warm load can't see), so a fragment hit serves the complete
  main-module variant even warm.
- **Serialisation** via Agda's `EmbPrj`, so `QName`s (NameIds, ranges)
  round-trip exactly. The byte layer is only exposed by Agda ≥ 2.9; on
  2.8 the flag warns + no-ops.
- `--incremental` / YAML `incremental: true`; disabled under
  `--keep-going`. All failure modes degrade to recompute, never abort.
  CI: cold-write + warm-hit must be byte-identical and match the golden.

## 2026-06-12 — `agda-deps` — golden snapshot regenerated from a cold run

The committed golden had been generated warm, freezing the degraded
main-module variant (missing `Test.Int-0`-class pattern-helper
edges/kinds/types — the "warm-`.agdai` edge loss"). The golden is now the
cold (complete) variant, and CI clears `.agdai` before the runs that feed
the golden check. The warm loss is main-module-only: imported modules'
emission is a pure function of their pruned interface.

## 2026-06-12 — `agda-deps` — expanded-graph invariants + golden snapshot (phase 3)

- **`toExpandedGraph`** extracted from `buildExpandedJson` (now a thin
  validate-then-encode wrapper).
- **`Wire.validateExpanded`** asserts the structural invariants JSON
  Schema can't express (provenance/subterm array lengths, edge endpoints
  name a definition); `buildExpandedJson` `error`s on a violation.
- **Golden snapshot guard**: `test/golden/expanded.golden.json` +
  `schema/golden_check.py` catch content regressions; the normaliser
  strips build/layout/path-volatile fields so it's portable. New CI step.
- Output byte-identical (refactor + new guards).

## 2026-06-12 — `agda-deps` — expanded emission routed through the schema source of truth (phase 2)

The expanded `graph.json` is now encoded from the same
`AgdaDeps.Backend.Wire` field tables that generate the schema, closing
the drift gap by construction.

- **`buildExpandedJson` builds an `ExpandedGraph` and calls
  `encodeExpanded`** (= `encodeObject expandedFields`). Each field-table
  row carries wire name, schema fragment, and byte encoder together, so a
  field can't be emitted without appearing in the generated schema. The
  old hand-rolled per-field assembly is gone.
- **`Wire` now owns the expanded wire tags** (`wireState`/`wireKind`/
  `wireAccess`); the duplicates in `GraphJson` were removed.
- Output byte-identical; `packed`/`--lazy` untouched (still in `GraphJson`).

## 2026-06-12 — `agda-deps` — expanded-schema single source of truth + drift check (phase 1)

Closes the silent-schema-drift gap: open `additionalProperties` let a new
producer field slip past validation undocumented.

- **`AgdaDeps.Backend.Wire`** describes the v2 expanded wire shape once
  (field tables + a small `SchemaDoc` ADT).
- **`agda-deps --emit-schema`** prints the JSON Schema generated from it.
- **`schema/check_schema.py`** + a CI step diff the generated schema
  against the committed oracle *structurally*; the committed file is
  never overwritten, so a wire-shape change must update it deliberately
  or the check fails.
- Schema-only: no new runtime fields, no reroute; output byte-identical.

## 2026-06-12 — `agda-deps` — `--version` reports the build fingerprint; install recipe

- **`--version` / `-V`** now print the full build fingerprint (version +
  git rev + build date + GHC), the same string stamped into `graph.json`
  as `"producer"`; previously only the bare semver. `--numeric-version`
  stays bare for tooling.
- **Documented `cabal install exe:agda-deps --overwrite-policy=always`**
  so callers get a stable on-`PATH` binary.
- **`AGDA_DEPS_GIT_REV` override** for `BuildInfoTH`: `cabal install`
  builds from an sdist with no `.git`, so the git splice otherwise
  reports `git unknown`; the env var lets an installer stamp the commit.
  In-tree builds are unaffected (git wins when present).

## 2026-06-05 — `agda-deps` — build provenance stamped into `graph.json`

- **Build fingerprint baked into every binary (`BuildInfo`)** — package
  version, git revision (`+` for a dirty tree), compile date, compiling
  GHC (TH for git, CPP for the date). Reported by `--version`.
- **Graph provenance in `graph.json`** — both emitters write `"producer"`
  and `"nodeKeyVersion"`. Additive/optional; older JSON parses with
  `nodeKeyVersion` defaulting to `1`.

## 2026-06-05 — `agda-deps` — same-named helpers no longer collapse (E1 node collision)

Node identity now keys on `nodeKey`: `prettyShow` for top-level names
plus a `@<binding-line>` suffix for `._.`-marked helpers, which
`prettyShow` otherwise renders identically across every same-named helper
in a module (so the last won and the rest's edges vanished). The
binding-site line is the one per-helper coordinate stable across
signature sources (`NameId` is not — hence the long-standing `hashQName
= prettyShow` invariant). `hashQName`, the wire `name`, and edge
endpoints all derive from `nodeKey`; the expanded-edge filter resolves
by canonical string, not `QName` `Ord`. Top-level keys byte-identical.
Regression in `test/Collision.agda`.

## 2026-06-05 — `agda-deps` — opt-in normalised / implicit signatures

**`--normalise-signatures`** reduces each type to semantic form before
reifying; **`--signature-implicits`** shows implicit/irrelevant args
(named to avoid clashing with Agda's `--show-implicit`). Both default
off, so default `--with-signatures` output is byte-identical.

## 2026-06-04 — `agda-deps` — rendered type signatures (`--with-signatures`)

Renders each definition's type — `prettyTCM` of `defType`, not
normalised, default printing, one line — as the optional per-def `"type"`
field in expanded JSON. Additive: absent without the flag, so default
output is byte-identical. Mirrored in YAML as `with-signatures`.

---

## 2026-06-01 — `agda-deps` — `--agda-html-dir` + sunburst "Open source"

New flag `--agda-html-dir=DIR` links the HTML views to the pages
`agda --html` already wrote, instead of embedding snippets with
`--with-source`. Emitted into every view's data-loading prelude as the
`AGDA_HTML_BASE` JS var (trailing-slashed, or `null` when absent),
interpreted relative to the generated HTML file. Plumbed like every other
flag (`Options` + parser + `commandLineFlags` + YAML `agda-html-dir` +
`NFData`).

First consumer: the **`sunburst-hierarchy`** view. When `AGDA_HTML_BASE`
is set, module arcs and the centre disc gain an **Open source ↗**
affordance (module link needs no char-offset anchor — the filename is
`<Module.Name>.html`); external/builtin modules are suppressed.
Everything gated on `AGDA_HTML_BASE`, so output is unchanged when the
flag is absent.

---

## 2026-05-29 — `agda-deps` — `--lenient-imports` docs, `--resolve-deps`, partial `--keep-going` emission

### `--lenient-imports` × `--safe` incompatibility documented

`--lenient-imports` is an argv rewrite to `--allow-unsolved-metas`; any
`--safe` module in the dep closure (including stdlib) rejects it with
`[SafeFlagPragma]`. Documented in `--help` and README, recommending
`--keep-going` alone for safe-stdlib projects.

### `--resolve-deps` flag

Opt-in resolution of the project's `.agda-lib` `depend:` closure into an
explicit `--no-libraries -i <dir> …` argv expansion. Use case: when
multiple versions of the same library are registered, Agda's resolver
picks ambiguously (`[AmbiguousTopLevelModuleName]`). New module
`AgdaDeps.LibResolve` reads `~/.agda/libraries`, walks the transitive
closure, and pins the include dirs. Wired through `Main.hs`; YAML
`resolve-deps: true`. Falls back silently (with a breadcrumb) if there's
no `.agda-lib` or a dependency can't be resolved.

### Partial def-level emission under `--keep-going`

Previously, when a downstream module fatally failed, all def-level data
from successfully-loaded modules was discarded — the graph collapsed to
module-level only. Two fixes:

1. **`catchError` now also wraps `setup`**, not just `check mainFile`,
   so a `TCErr` before checking starts (e.g. `OptionError`,
   `SafeFlagPragma`, library-resolution ambiguity) is reported, not
   escaped.
2. **The failure branch re-drives `preModule → compileDef → postModule`
   per decoded module**, accumulating results for `postCompile`; each
   module's hooks are wrapped so one broken module is skipped.

Load-bearing: before the loop, every decoded interface's `iSignature` is
merged into `stImports` and `stSignature` cleared — without this,
downstream `getConstInfo` in `contractIgnoredEdges` fails with `Unbound
name` panics on cross-module dep edges. Normal mode is byte-identical.

---

## 2026-05-29 — `agda-deps` — remove the 14 view-shortcut boolean flags

Drop the deprecated per-view shortcut flags (`--cytoscape`, `--sigma`,
`--module-dag-pods`, `--ide-three-pane`, `--source-centric`,
`--notion-doc`, `--wiki-backlinks`, `--big-module-dag-pods`,
`--critical-path-holes`, `--progress-dashboard`, `--cartographic-atlas`,
`--sunburst-hierarchy`, `--reading-order-narrative`,
`--pixel-grid-overview`). Deprecated 2026-05-27; passing one now errors
as an unrecognised option. The replacement remains `--view=NAME` (or
`view: NAME` in YAML). Removal drops `setViewShortcutOpt` and the
`optSawViewShortcut` field; the `View` ADT, `viewSlug`, and `viewOpt`
parser stay.

---

## 2026-05-28 — `agda-deps` — round-6 P3 (AST subterm fingerprinting)

Cross-file CSE / lemma-extraction candidate detection over canonicalised
internal `Term`s.

- **`AgdaDeps.TermCanon`** — canonical-form byte encoder for
  `Agda.Syntax.Internal.Term`. Two terms hash equal iff alpha-equivalent
  up to: de-Bruijn `Var` indices, positions stripped, `MetaV` wildcarded,
  hidden bit preserved, provenance (`ConInfo`/`ProjOrigin`/…) dropped;
  `QName`/`Sort`/`Level`/`Literal` via `prettyShow` (same convention as
  `hashQName`, so module aliases collapse). Single bottom-up walk returns
  `(encoding, depth, [(hash, depth)])`, reusing the encoding at the parent.
- **`--with-term-hashes`** (off by default) — walks `defType` + every
  clause body; populates parallel `_subtermHashes :: Maybe [Word64]` and
  `_subtermDepths :: Maybe [Int]`.
- **`--min-term-depth=N`** — emission threshold, default `3` (`1`
  disables filtering); cuts hash volume substantially.
- **Two optional wire fields** in expanded JSON at `schemaVersion: 2`:
  `definitionSubtermHashes` and `definitionSubtermDepths`, both parallel
  to `definitions`; inner-array lengths must match (enforced at decode).
  Default-mode JSON is byte-identical (both fields absent, not empty).

---

## 2026-05-27 — `agda-deps` — YAML config (`.agda-deps.yml`)

`agda-deps` now reads a YAML config from a project-local file (or
explicit `--config=PATH`), promoting the shell-wrapper preambles projects
used into a real format. New module `AgdaDeps.Config` composes on top of
the existing surface via `applyConfig :: A.Object -> Options -> Either
String Options`; `Options` and `commandLineFlags` are untouched.

- Top-level keys are kebab-case mirrors of CLI flag names; repeatable
  flags accept YAML lists. Bad type / unknown key fails fast naming file
  + key, exit 1.
- Discovery (first match wins): `--config=PATH` > `$AGDA_DEPS_CONFIG` >
  `./.agda-deps.yml`(`.yaml`) > walk up to the first ancestor with a
  `*.agda-lib` and pick its dotfile.
- Merge order: **defaults → config → CLI**. A stderr breadcrumb fires
  once when a config applies, unless `--quiet`.

Example:

```yaml
format: html
view: module-dag-pods
theme: dark
no-externals: true
keep-going: true
with-source: true
lazy: true
exclude:
  - Agda.Builtin
  - Data
no-source-for:
  - Foreign
color-defined: "#4caf50"
color-postulate: "#f44336"
max-snippet-bytes: 1000000
json-mode: expanded
gzip: false
quiet: false
out-dir: build/deps
```

Two CLI simplifications shipped alongside:

- **`--theme=default|light|dark|colorblind`** — single-flag preset for
  the four state colours. Explicit `--color-*=#RRGGBB` still wins. YAML
  `theme:`.
- **Auto-format inference from `-o`** — when `--format` is not set and
  `-o` ends in `.html`/`.json`/`.dot`, the format is inferred. Explicit
  `--format=…` always wins; directories/extension-less names keep the
  default (`dot`).
- **Per-view shortcut flags deprecated** — still work, but emit a
  one-time stderr note; use `--view=NAME`.

Added build-dep `yaml >= 0.11 && < 0.12`.

---

## 2026-05-27 — `agda-deps` — edge-provenance tagging

Expanded JSON now carries an optional `definitionEdgesProvenance` array,
parallel to `definitionEdges`, tagging each edge `signature | body |
where | with | unknown`. `AgdaDeps.Deps`:

- Walks `defType` and `theDef` **separately**.
- Names in `defType` are `Signature`; names in `theDef` are `Body`,
  refined to `With` when the parent's `funWith` points at the target and
  `Where` when the qname's `prettyShow` contains the `._.` marker.
- Combines via precedence `Signature > With > Where > Body > Unknown`.

`ADDef` gained a strict `_depsProv :: !(Map QName EdgeProv)` with the
invariant `M.keysSet _depsProv == _deps`. `IgnoredEdgeMap` was widened to
carry provenance through `contractIgnoredEdges` — contracted edges
inherit the **source** side's tag. Packed mode emits an `Int8` array
parallel to `outTargets` (`0=signature,1=body,2=where,3=with,4=unknown`).
Schema stays at `v=2`; the field is additive.

---

## 2026-05-27 — `agda-deps` — lazy-mode placeholder detail files for modules with no kept defs

`--lazy` declared `moduleFiles[m]` entries for modules whose detail JSON
was never written (externals like `Agda.Primitive`, and project modules
where every def was filtered), so the JS fetched a 404. Root cause:
`buildGraphJson` populated `moduleFiles` for every module, but
`buildModuleDetails` only emitted files for modules with entries in
`defsByModule`.

Fix: `buildModuleDetails` now emits a stub detail JSON for every module
in `moduleFiles` absent from `defsByModule`, with discriminators
`placeholder: true`, `reason: external|filtered|failed`, and optional
`externalPostulates`. Eight view templates gained
`placeholderReasonText` + `renderPlaceholderHTML` and a guard at the
fetch site. Schema stays at `v=2`; non-lazy and expanded modes unaffected.

---

## 2026-05-26 — `agda-deps` — `--no-externals` actually drops externals + `externals_summary`

### `--no-externals` actually drops externals

`--no-externals` was still emitting hundreds of stdlib module names. Root
cause: `classifyExternalModules` derived its external set only from
QNames with a resolvable source path, but Agda's compiler-builtins carry
`rangeFile = Nothing`, and stdlib modules visible only as import-edge
endpoints had no surviving QName.

Fix: `classifyExternalModules` now takes three signals — QNames,
`precomputedModuleFiles`, and all import-edge endpoint module names —
and treats a module as external when *no* signal places its source under
the project root. The `keep` predicate is applied to `moduleFileMap` too
(the single source of truth for module-level wire filtering) so
`moduleFiles` can't leak an external path. Default output unchanged.

### `externals_summary` top-level field

A new top-level `externals_summary` tags dropped externals so a
diagnostic record of the trusted base survives `--no-externals`.
Collected *before* `dropExternalDefs` runs; omitted entirely when
`--no-externals` is off (byte-identical otherwise).

```json
"externals_summary": {
  "modules": ["Agda.Builtin.Bool", "Agda.Primitive", ...],
  "postulates_by_module": {
    "Agda.Builtin.Bool": ["true", "false"],
    ...
  }
}
```

`buildExternalsSummary` filters defs by `state == Postulate`, groups
unqualified names by module, and feeds both packed and expanded output.
The `--skip-agda` path initialises it to `Nothing` (no postulates seen).

---

## 2026-05-26 — `agda-deps` — per-definition `line`, `access`, instance reverse edges

- **`line` per definition** — `_line :: !(Maybe Int)` via
  `nameBindingSite` → `rStart` → `posLine`. Emitted in expanded JSON
  (omitted when unknown); packed unchanged.
- **`access` per definition** — `_access :: !(Maybe DefAccess)`. Agda
  discards the per-decl `Access` tag after scope-checking, so this uses a
  source-level pre-scan (`findPrivateRanges`) for top-level `private`
  blocks at column 0; `backfillAccess` matches each def's `_line` against
  those ranges. Emitted as `"access": "private" | "public"`.
- **Instance-declaration reverse edges** — new `methodProvidersRef`
  side-channel. `recordInstanceMethods` (in `compileDefAD`) records
  `defInstance` binders + projection-method QNames off head clause
  patterns; `addInstanceMethodEdges` (after `contractIgnoredEdges`)
  appends providers to any kept def's dep that's a method key. Additive.

---

## 2026-05-25 — `agda-deps` — node-identity and dead-private recovery fixes

- **`ignoreDef` filters every `defCopy`** — module-instantiation copies
  for `Record`/`Datatype`/`Constructor`/`Projection`, not just
  `Function`; previously surfaced as ghost entries under the importer.
- **`hashQName` via `prettyShow`** — was hashing derived-`Show`, which
  included `NameId` metadata that differs between `iSignature` and
  `stSignature` sources, collapsing duplicate nodes.
- **Dead-end private definition recovery in `postModuleAD`** — Agda's
  `eliminateDeadCode` prunes unreachable top-level `private` defs from
  `iSignature`; we diff `getSignature` (pre-prune) against visited QNames
  and feed missing defs through `compileDefAD`.

---

## 2026-05-23 — Feature batch for re-exports / kind / edge contraction

### Edge contraction through ignored defs

Headline correctness fix: `with-`clauses elaborate to `parent →
with-NNN → target`, and `ignoreDef` was dropping the `with-NNN` and
losing the edge. `ignoredEdgesRef` records the raw out-edges of every
ignored def; `contractIgnoredEdges` (in `postCompileAD`) rewrites each
kept def's `_deps` by expanding hidden refs into their transitive
non-hidden targets, via a topsort-based DP (Kahn) linear in hidden-node
count. Side-effect: `ignoreDependency` filtering moved from
`computeDefAD` to `contractIgnoredEdges` so raw hidden refs survive to be
expanded. Roughly doubled edge counts on the reference corpus.

### `kind` discriminator on definitions

Each `ADDef` carries `_kind :: !DefKind` derived structurally from
`theDef`: `function`/`projection`/`datatype`/`record`/`constructor`/
`postulate`/`primitive`/`other`. Emitted in expanded JSON so consumers
filter without string-scraping qnames. Agda 2.9's `funProjection` is
`Either ProjectionLikenessMissing Projection`; projection matches
`Right{projProper = Just _}`.

### `reexports[]` in expanded JSON

Captures `open import M public` and parameterised-module re-exports. The
producer walks each visited `Interface`'s `iScope` over both
`ImportedNS` (plain `open … public`) and `PublicNS` (re-exports through
parameterised applications) namespaces. `iScope` is reconstructed from
`iInsideScope` at deserialise time, so the data survives cached `.agdai`.

---

## 2026-05-22 — G12 · external feature-request batch

Shipped 9 of 14 items from an external feature-request batch; the rest
are in [Backlog.md](Backlog.md).

- `--version` / `-V` / `--numeric-version` — early intercept in `Main`;
  reports the backend's version, not Agda's.
- `--quiet` — silences progress chatter via `AgdaDeps.Logging.info`,
  backed by a global `quietRef`.
- `--no-externals` — drops external modules from the rendered graph.
- `--json-mode=packed|expanded` — selects `--format=json` shape.
  Expanded ships `definitions` as `[{id, name, module, state, x?, y?}]` +
  string edge pairs + explicit `schemaVersion` and `mode`.
- `--lenient-imports` — rewritten in `Main.hs` to
  `--allow-unsolved-metas`; useful with `--keep-going` on projects with
  deliberate `?` holes.
- `-o` directory auto-created via `createDirectoryIfMissing True`.
- `Options` grew `JsonMode`, plus `optQuiet`, `optNoExternals`,
  `optJsonMode`, `optLenientImports`.
- `CLAUDE.md` gained the "State semantics" (D/P/H/F) and "v2 graph.json
  schema" sections.

---

## G11 — `--skip-agda`

Short-circuits the entire Agda pipeline. `Main.hs` routes `--skip-agda`
to `AgdaDeps.SkipAgda.runSkipAgda`, consuming the line-parsed `module …`
/ `import …` declarations `AgdaDeps.Precompute` already produces.

- Backend options parsed via `getOpt' Permute` + `runOptM`.
- `Precompute.parseHeader` falls back to `takeBaseName path` for
  `module _ where`.
- `GraphInput` got `giExtraModules :: Set String` so orphan modules
  appear; `renderHtmlFromInput` exposed for `SkipAgda`.

Trade-off: no def graph, no D/P/H, no snippets. Module-DAG views render;
def-level views show empty pods. Runs in milliseconds regardless of size.

---

## G10 — Scaling to ~1M defs / 100k modules

Audited the pipeline for O(n²) hot spots; switched to strict
`Map`/`IntMap`/`IntSet`/`Set` folds throughout. Byte-identical output.

- `Layout.moduleGrouped` — `IntMap` cons-accumulation (was
  `M.fromListWith` with `(++)`).
- `GraphJson.bfsFrom`/`bfsDepths` — `Data.Sequence` instead of list queues.
- Six `nub` sites collapsed to Set-based dedup.
- `moduleEdgePairs` — folds into `Set (Int, Int)`.
- `Deps.collectAllQNames` — folds into `IntMap QName`.
- `Csr.buildCsr` — fused `length` + `concatMap` into one strict sweep.
- `Backend.computeQNamePositions` — `IntSet`/`IntMap`, cheap membership
  test first.
- `moduleStateCounts` — strict `data Counts !Int !Int !Int !Int`.
- `buildSearchIndex` bigrams gated above 50k names; JS falls back to
  linear scan.

---

## G9 — Multi-view HTML system

Replaced the single cytoscape template with a `View` ADT and one template
per view under `src/AgdaDeps/templates/views/`, all consuming the same v2
`graph.json`:

- `module-dag-pods` *(default)* — top-down DAG of expandable module pods
  via dagre.
- `cytoscape` — original compound-node viewer.
- `ide-three-pane`, `source-centric`, `notion-doc`, `wiki-backlinks` —
  definition-level views.
- `sigma` — WebGL via sigma.js + graphology + dagre; falls back to
  concentric above 3000 modules.
- `big-module-dag-pods` — viewport-virtualised port for ~100k modules.
  Dagre layout pre-computed Haskell-side (`buildModuleDagLayout`, Kahn +
  column-pack, O(V+E)), packed as `modulePodLayout`; JS uses a
  spatial-grid + minimap.
- `progress-dashboard`, `critical-path-holes` — KPI / kanban dashboards.
- `sunburst-hierarchy`, `cartographic-atlas`, `reading-order-narrative`,
  `pixel-grid-overview` — hierarchical / textbook / heatmap views.

---

## G8 — Custom `--help` (`AgdaDeps.Help`)

Agda's own `--help` lists hundreds of flags. `Main.hs` intercepts plain
`--help` / `-h` / `-?` and routes to `printHelp`, which uses
`usageInfo` over only the backend's `commandLineFlags`. Topic forms
(`--help=warning`) still forward to Agda; new `--agda-help` is rewritten
to plain `--help` for Agda's upstream printer.

---

## G7 — Partial compilation under `--keep-going`

`Agda.Main.runAgda` aborts on the first `TCErr`, so `postCompile` never
fires. Forked into `AgdaDeps.ModuleExplorer`:

- `partialBackendInteraction` catches `TCErr` from `check mainFile`,
  records the failing module via `reportFailed :: String -> IO ()`, and
  drives each backend manually over the modules Agda did load.
- `partialCompilerMain` re-seeds `stVisitedModules` from
  `stDecodedModules`, runs `preCompile`, then `postCompile`.
- `AgdaDeps.Driver` is a thin shim wiring `failedModulesRef` to the callback.

---

## G6 — Auto-discover `.agda-lib` for non-cwd invocations

Plain `agda` only looks for `.agda-lib` in cwd, so invocations from
outside the project failed (library deps never consulted). Pre-process
argv before `runAgdaArgs`: canonicalize path-bearing entries to absolute
paths first (so a relative `-o foo/` resolves against the user's cwd),
then walk up from each `-i` and each `.agda`/`.lagda*` positional for an
ancestor containing a `*.agda-lib` and `setCurrentDirectory` to it. Skip
the dance when `--no-libraries`, `--library`/`-l`, or `--library-file` is
already passed.

---

## G5 — Bump to Agda 2.9

- `cabal.project` pins Agda as a `source-repository-package` from
  `github.com/agda/agda` (2.9.0 isn't on Hackage yet).
- `agda-deps.cabal`: `Agda >= 2.9 && < 3`.
- `graphviz >= 2999.20` to dodge older versions' `<>` ambiguity on GHC ≥ 9.
- Adapted `_funWith :: Maybe QName` → `IsWithFunction QName` via `isWithFun`.

---

## G4 — Linked source view (`--with-source`)

`--with-source` embeds each definition's source in a slide-in drawer,
rendered with Agda's native semantic highlighting. Drives Agda's
`defaultPageGen` programmatically from `postCompileAD`:

1. Per-module Agda HTML to a temp dir under `-o`.
2. Extract the `<pre class="Agda">` block from each file.
3. Per leaf QName: find binding line via `srcLocOf`, compute paragraph
   bounds against the cached source, slice the highlighted HTML by line.
4. Inline `source` + `sourceLine` on each node's JSON; remove temp dir.

Line slicing is safe because Agda's rendered `<pre>` keeps newlines as
plain text *outside* any `<a>` tag.

---

## G3 — Node colouring by state

Definitions classified `Defined` / `Postulate` / `Hole`, tagged on
`ADDef`. Palette via `--color-defined` / `--color-postulate` /
`--color-hole` (defaults `#4caf50` / `#f44336` / `#9c27b0`); both DOT and
HTML honour it. Hole detection has three signals because Agda's
`openMetasToPostulates` rewrites `?` into synthetic `unsolved#meta.*`
postulates before backends fire: a syntactic `MetaV` walk, the def's own
name, and references to synthetic-meta names.

---

## G2 — HTML interactive backend

Added `--format=dot|html` and a self-contained browser-explorable HTML
output backed by [cytoscape.js](https://js.cytoscape.org/). Modules as
collapsible compound parent nodes (`cytoscape-expand-collapse`); cytoscape
loaded from CDN, graph inlined as JSON. Output routed via `-o/--out-dir`.

---

## G1 — Remove nix scaffolding

Stripped `flake.nix` / `flake.lock`. Project builds purely via `cabal`.
