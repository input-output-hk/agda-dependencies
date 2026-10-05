#!/usr/bin/env python3
"""Check declaring source paths across re-exports and incremental reuse.

Usage: module_files_check.py /path/to/agda-deps [old-binary]
The optional old binary seeds the incorrect mapping during a partial rebuild;
the current binary must repair it without replacing extracted fragments.
All sources, interfaces, caches and outputs live in a temporary directory.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from packed_analytical_check import dec, decode_expanded, decode_lazy, decode_packed


def snapshot(directory, pattern):
    return {
        p.relative_to(directory): (p.read_bytes(), p.stat().st_mtime_ns)
        for p in directory.rglob(pattern)
    }


def check(binary, root, mode, previous=None):
    project = root / "project"
    for directory in (project / "Prelude" / "PFin", project / "z", root / "registry"):
        directory.mkdir(parents=True)
    (project / "project.agda-lib").write_text("name: project\ninclude: .\n")
    config = root / "empty.yml"
    config.write_text("{}\n")
    env = dict(os.environ, AGDA_DIR=str(root / "registry"))
    env.pop("AGDA_DEPS_CONFIG", None)
    cache = root / "cache"
    output = root / "output"

    sources = {
        "Prelude.agda": "module Prelude where\npostulate marker : Set\n",
        "Prelude/PFin.agda": """{-# OPTIONS --safe #-}
module Prelude.PFin where
open import Agda.Builtin.Nat

pweaken : Nat → Nat
pweaken n = n

pweaken-injective : Nat → Nat
pweaken-injective n = n

module Nested where
  identity : Nat → Nat
  identity n = n
""",
        "Prelude/PVec.agda": """{-# OPTIONS --safe #-}
open import Agda.Builtin.Nat
module Prelude.PVec (n : Nat) where

open import Prelude.PFin public
  using (pweaken)
  renaming (pweaken-injective to ↑-injective)

local : Nat
local = pweaken n
""",
        # Sort after PFin: collectAllQNames can otherwise replace the
        # renamed reference with the original definition and mask the bug.
        "ZEntry.agda": """module ZEntry where
open import Agda.Builtin.Nat
import Prelude
open import Prelude.PVec 0 public

entry : Nat
entry = pweaken 1
""",
        # These unimported sources must stay in the scan inventory without
        # being checked. The child must keep its own file, not its parent's.
        "Prelude/PFin/Unused.agda": "module Prelude.PFin.Unused where\nbad : Unknown\n",
        # The scanner sees duplicate module declarations in these files,
        # but Agda loads PFin.agda and homes Nested in that same file.
        "z/Shadow.agda": "module Prelude.PFin where\n",
        "z/NestedShadow.agda": "module Prelude.PFin.Nested where\n",
    }
    for name, content in sources.items():
        (project / name).write_text(content, encoding="utf-8")
    expected = {
        "Prelude": str(project / "Prelude.agda"),
        "Prelude.PFin": str(project / "Prelude/PFin.agda"),
        "Prelude.PFin.Nested": str(project / "Prelude/PFin.agda"),
        "Prelude.PFin.Unused": str(project / "Prelude/PFin/Unused.agda"),
        "Prelude.PVec": str(project / "Prelude/PVec.agda"),
        "ZEntry": str(project / "ZEntry.agda"),
    }

    def cold():
        for path in project.rglob("*.agdai"):
            path.unlink()

    def run(label, incremental=False, exe=binary):
        flags = ["--lazy"] if mode == "lazy" else []
        if incremental:
            flags += ["--incremental", "--cache-dir", str(cache)]
        result = subprocess.run(
            [str(exe), "--config", str(config), "--no-libraries", "--format=json",
             f"--json-mode={'packed' if mode == 'lazy' else mode}",
             "--no-externals", "--packed-analytical", "--with-signatures",
             "--signature-implicits", "--with-term-hashes", "--min-term-depth=3",
             *flags, "-i", str(project), "-o", str(output),
             str(project / "ZEntry.agda")],
            cwd=project, env=env, capture_output=True, text=True,
        )
        assert result.returncode == 0, (mode, label, result.stdout, result.stderr)
        path = output / ("graph.json" if mode == "lazy" else "deps.json")
        graph = json.loads(path.read_text(encoding="utf-8"))
        if mode == "expanded":
            mapping = graph["moduleFiles"]
            definitions = decode_expanded(graph)[0]
        else:
            mapping = {
                module: graph["files"][index]
                for module, index in zip(graph["modules"],
                                         dec(graph["moduleToFile"], "<i", 4))
                if index >= 0
            }
            definitions = (decode_lazy(output) if mode == "lazy"
                           else decode_packed(graph))[0]
        return graph, mapping, definitions, result.stdout + result.stderr

    def verify(result, wrong=False):
        graph, mapping, definitions, _ = result
        wanted = dict(expected)
        if wrong:
            wanted["Prelude.PFin"] = expected["Prelude.PVec"]
        assert mapping == wanted, (mode, wanted, mapping)
        assert set(mapping) <= set(graph["modules"]), graph["modules"]
        for name, line in (("pweaken", 5), ("pweaken-injective", 8)):
            node = f"Prelude.PFin.{name}"
            assert definitions[node]["line"] == line, (node, definitions[node])
            declaring_line = (project / "Prelude/PFin.agda").read_text().splitlines()[line - 1]
            assert declaring_line.startswith(name + " :"), declaring_line
        assert "Prelude.PFin.Nested.identity" in definitions, definitions
        assert not any(n.startswith("Prelude.PFin.Unused.") for n in definitions)
        if mode == "expanded":
            row = next(r for r in graph["reexports"]
                       if r["from"] == "Prelude.PVec" and r["to"] == "Prelude.PFin")
            assert row["renames"] == {"↑-injective": "Prelude.PFin.pweaken-injective"}, row

    verify(run("cold"))
    verify(run("warm"))
    cold()
    seed = previous or binary
    verify(run("incremental-miss", incremental=True, exe=seed))
    before = snapshot(output, "*.json")
    result = run("incremental-hit", incremental=True, exe=seed)
    verify(result)
    assert "fragment hit for 'ZEntry'" in result[3], result[3]
    assert snapshot(output, "*.json") == before, mode
    if mode != "lazy":
        assert "skipped re-emit" in result[3], result[3]

    # Hits bypass mkRef for the imported definitions. The rebuilt consumer
    # creates a NodeRef for the renamed QName carrying PVec's binding range.
    entry = project / "ZEntry.agda"
    entry.write_text(sources["ZEntry.agda"].replace("entry = pweaken 1",
                                                   "entry = ↑-injective 2"))
    result = run("partial-miss", incremental=True, exe=seed)
    verify(result, wrong=previous is not None)
    for module in ("Prelude", "Prelude.PFin", "Prelude.PVec"):
        assert f"fragment hit for '{module}'" in result[3], result[3]
    assert "fragment hit for 'ZEntry'" not in result[3], result[3]
    assert "skipped re-emit" not in result[3], result[3]

    # New references with rename locations may remain in the fragments.
    # Re-emission must repair the module path while those fragments survive.
    before_fragments = snapshot(cache, "*.frag")
    result = run("all-hit-after-partial-miss", incremental=True)
    verify(result)
    assert "fragment hit for 'ZEntry'" in result[3], result[3]
    assert snapshot(cache, "*.frag") == before_fragments, mode
    if previous:
        assert "skipped re-emit" not in result[3], result[3]

    before = snapshot(output, "*.json")
    verify(run("unchanged", incremental=True))
    assert snapshot(output, "*.json") == before, mode
    # Force emission on an all-hit run so the serialization skip cannot
    # hide a wrong path reconstructed from the saved renamed references.
    (output / ("graph.json" if mode == "lazy" else "deps.json")).unlink()
    result = run("all-hit-reemit", incremental=True)
    verify(result)
    assert "fragment hit for 'ZEntry'" in result[3], result[3]
    assert "skipped re-emit" not in result[3], result[3]
    assert snapshot(cache, "*.frag") == before_fragments, mode
    verify(run("non-incremental-after-edit"))
    print(f"module source paths OK ({mode}, cold/warm, partial/all cache hits"
          + (", old-output repair)" if previous else ")"))


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve(strict=True)
    previous = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) == 3 else None
    with tempfile.TemporaryDirectory(prefix="agda-deps-module-files-") as tmp:
        for mode in ("expanded", "packed", "lazy"):
            check(binary, Path(tmp) / mode, mode, previous)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
