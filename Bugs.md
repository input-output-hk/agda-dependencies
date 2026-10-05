# Bugs

## moduleFiles assigns a re-exported module to the importing file

**Status:** Producer fix implemented 2026-10-05. Reported 2026-10-04 during
Jolteon-FastBFT MCP validation. Consumer coverage and rebuild-selection
integration still need verification against regenerated project artifacts.

### Observed behavior

The graph contains the definitions of `Prelude.PFin`, but its source-file
mapping assigns that module to `Prelude/PVec.agda`:

```json
{
  "Prelude.PFin": "/home/mceresa/Repositories/Jolteon-FastBFT/agda-src/Prelude/PVec.agda"
}
```

The expected path is
`/home/mceresa/Repositories/Jolteon-FastBFT/agda-src/Prelude/PFin.agda`.
That file declares `module Prelude.PFin where`. The importing module is
parameterized and publicly re-exports two definitions, with one renamed:

```agda
module Prelude.PVec {n} (P : Pred (Fin n) ℓ) ⦃ _ : P ⁇¹ ⦄ where

open import Prelude.PFin public
  using (pweaken)
  renaming (pweaken-injective to ↑-injective)
```

The exported definitions retain their original names and source line numbers:

| Definition | Line in PFin.agda |
| --- | --- |
| `Prelude.PFin.len≡@11` | 11 |
| `Prelude.PFin.pweaken` | 22 |
| `Prelude.PFin.pweaken-injective` | 35 |

Confirmed in both the published project graph and the individual producer
artifact whose `entryModule` is `Extras.Liveness3Delta`. The incorrect path is
therefore present before agda-explore unions the entry graphs.

### Environment and evidence

- Producer: `agda-deps 1.1 (git unknown, built Oct 2 2026 16:11:19, ghc 9.12)`.
- Agda 2.8.0; expanded JSON schema v2; node-key version 3.
- Producer flags: `--format=json --json-mode=expanded --no-externals
  --incremental --with-term-hashes --min-term-depth=3 --with-signatures
  --signature-implicits`.
- Project: `/home/mceresa/Repositories/Jolteon-FastBFT`.
- Published artifact: `.agda-explore/deps.json`.
- Verified generation: `generation-a97999bce118c460-1`.
- Per-entry evidence:
  `.agda-explore/generations/generation-a97999bce118c460-1/entries/a35681a0bee671d2/deps.json`
  (`entryModule: Extras.Liveness3Delta`).
- The build completed with exit 0, stable inputs, and no failed modules.

This was observed with existing Agda interfaces and incremental fragments.
A minimal reproduction on Agda 2.8 and 2.9 confirms that cold and ordinary
warm exports are correct; mixing imported-module fragment hits with a rebuilt
consumer that uses the renamed definition introduces the incorrect path.
Later all-hit exports preserve it.

Inspect either affected artifact with:

```sh
python3 - /home/mceresa/Repositories/Jolteon-FastBFT/.agda-explore/deps.json <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    graph = json.load(stream)
print(graph["moduleFiles"]["Prelude.PFin"])
for definition in graph["definitions"]:
    if definition["module"] == "Prelude.PFin":
        print(definition["name"], definition.get("line"))
PY
```

### Consumer impact

agda-explore uses `moduleFiles` for source locations and import-closure coverage.
Consequently, source navigation pairs PFin line numbers with the wrong file,
and live status falsely reports `Prelude/PFin.agda` as outside every entry's
import closure. Its definitions are present and searchable.

The wrong closure path can also affect which entries are selected after a PFin
edit; that consequence is inferred from the consumer's closure-based rebuild
selection and has not been tested. Adding a coverage-ignore entry would only
hide the warning and would leave the source mapping incorrect.

### Confirmed cause and fix

Previously, [Backend.hs](src/AgdaDeps/Backend.hs) constructed
`moduleFileMap = M.union bindingFiles scannedFiles`. The binding map pooled
definitions and dependencies from `allQNames`, selected one path per module,
and overrode the scanned source path.

The cached definition of `Prelude.PFin.pweaken-injective` carries
`PFin.agda:35`, while references through the public rename can carry
`PVec.agda:11` with the same canonical node identity. Fragment hits skip
`mkRef` for the imported definitions; a freshly compiled consumer then records
the renamed reference's location. Deduplication can retain that reference
instead of the declaring definition, assigning the entire module to PVec.

The fix resolves each loaded top-level module through Agda's module-to-source
cache using `findFile'` and `srcFilePath`, which are shared by Agda 2.8 and 2.9.
Nested modules with QNames use the longest matching loaded top-level module
prefix, with dot boundaries. Source-only scanned children keep their own
files. These authoritative paths take precedence over scanned paths, with
QName binding locations retained only as a fallback.

An output-token marker forces existing incorrect JSON to be regenerated while
reusing definition fragments. Wire, node-key and fragment payload versions
remain unchanged.

### Regression coverage

[module_files_check.py](schema/module_files_check.py), run by both Agda CI jobs,
uses a parameterized public re-export and a consumer named `ZEntry`. The
consumer sorts after the defining module so QName deduplication cannot mask
the bug by selecting the original definition afterward. It checks:

- Correct declaring paths and definition lines in cold, warm, incremental miss,
  partial miss, all-hit and forced re-emission exports.
- Expanded, packed and lazy source mappings, including duplicate scanned
  declarations, nested modules and an unimported child with its own file.
- Stable output on unchanged runs and preserved fragments during re-emission.
- Repair of older incorrect output without rewriting fragments when an old
  producer binary is supplied as the optional second argument.

The supported Agda builds also retain the existing cold expanded golden.
Consumer integration remains to check that regenerated PFin paths remove the
coverage warning and that editing PFin selects its dependent entry closures.
