# Known bugs

This file tracks confirmed defects that require an intentional behavior or
wire-contract decision.  Behavior-preserving hardening belongs directly in the
implementation; the items below are deliberately not silently folded into an
unrelated cleanup.

## Skip mode retains external file metadata

With `--skip-agda --no-externals`, modules and edges are filtered but
`moduleFiles` and `sourceFiles` are emitted from the unfiltered pre-computed
scan.  This can leave `moduleFiles` keys absent from `modules` and paths outside
the selected project root in the output.

## Project containment is a textual prefix test

External classification currently uses `root `isPrefixOf` normalise path`.
For example, `/work/project-old/X.agda` is classified as being under
`/work/project`.  Containment needs to be path-component-aware, with a stated
policy for symlinks.

## Argument preprocessing disagrees with Agda/GetOpt

Several pre-parser paths do not have the same semantics as the final option
parser:

- relative `--config` and `AGDA_DEPS_CONFIG` paths are resolved after changing
  to the discovered project root;
- a trailing `--config` is removed instead of producing a missing-argument
  diagnostic;
- output-format inference uses the first `-o`, while the final parser uses the
  last occurrence; and
- attached short forms such as `-oDIR`, `-iDIR`, and `-lLIB` are not handled by
  project discovery/canonicalisation even though GetOpt accepts them.

The appropriate fix is one lossless argv-normalisation pass shared by every
pre-Agda decision.

## Dependency resolution can pin a partial closure

`--resolve-deps` performs exact string lookup of library names and skips a
missing transitive dependency while retaining successfully resolved siblings.
This differs from Agda's versioned-library matching and from the documented
all-or-nothing fallback.  On the Jolteon registry, `prettyprint-1.0` depends on
`standard-library`; only versioned `standard-library-2.x` entries exist, so the
custom resolver warns and still pins a partial closure.

## Normal YAML loading accepts invalid scalar values

The normal config decoder accepts malformed `color-*` values and
`min-term-depth` below one even though the equivalent CLI flags reject them.
An invalid colour later falls through to black in DOT rendering.  `doctor`
detecting the problem does not protect ordinary execution.

## CLI theme/colour precedence depends on argv order

YAML consistently applies a theme before individual colour overrides.  The
CLI instead folds actions in argument order, so a later `--theme` erases an
earlier `--color-*` override despite the documented override semantics.

## Lazy output leaves obsolete detail files

Reusing a lazy output directory writes the new manifest and current module
details but does not remove no-longer-referenced `modules/*.json` files or
obsolete gzip siblings.  Manifest-following consumers are safe, but copied or
inspected output trees accumulate stale generated artifacts.

## Some graph algorithms collapse identity to a 64-bit hash

`NodeRef` equality uses `(hash, key)` and therefore survives a hash collision,
but node collection, ignored-edge BFS, DOT identifiers, and layout identifiers
use the hash alone.  A collision is extremely unlikely but can merge nodes or
lose reachability despite the collision-safe identity contract.
