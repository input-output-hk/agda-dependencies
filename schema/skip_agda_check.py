#!/usr/bin/env python3
"""Check skip-mode file metadata with and without --no-externals.

Usage: python3 schema/skip_agda_check.py /path/to/agda-deps
Creates a temporary project and library; no Agda type-checking is needed.
"""

import base64
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def int32s(value):
    raw = base64.b64decode(value)
    return struct.unpack(f"<{len(raw) // 4}i", raw)


def check(binary, root):
    project = root / "project"
    # A sibling sharing the root's text prefix must still be external.
    library = root / "project-old"
    (project / "Local").mkdir(parents=True)
    library.mkdir()
    (project / "project.agda-lib").write_text("name: project\ninclude: .\n")
    sources = {
        project / "Entry.agda": (
            "module Entry where\nopen import Local\n"
            "open import Library\nopen import Unresolved\n"
        ),
        project / "Local.agda": "module Local where\n",
        project / "Local" / "Empty.agda": "module Local.Empty where\n",
        project / "NoHeader.agda": "-- No module declaration.\n",
        library / "Library.agda": "module Library where\n",
        library / "Unused.agda": "module Unused where\n",
        library / "NoHeader.agda": "-- No module declaration.\n",
    }
    for path, text in sources.items():
        path.write_text(text, encoding="utf-8")

    local_modules = {"Entry", "Local", "Local.Empty"}
    external_modules = {"Library", "Unused", "Unresolved"}
    module_files = {
        "Entry": str(project / "Entry.agda"),
        "Local": str(project / "Local.agda"),
        "Local.Empty": str(project / "Local" / "Empty.agda"),
        "Library": str(library / "Library.agda"),
        "Unused": str(library / "Unused.agda"),
    }

    for mode in ("expanded", "packed", "lazy"):
        for no_externals in (False, True):
            label = f"{mode}-{'local' if no_externals else 'all'}"
            output = root / label
            flags = ["--lazy"] if mode == "lazy" else []
            if no_externals:
                flags.append("--no-externals")
            result = subprocess.run(
                [str(binary), "--skip-agda", "--quiet", "--no-libraries",
                 "--format=json",
                 f"--json-mode={'packed' if mode == 'lazy' else mode}",
                 *flags, "-i", str(project), "-i", str(library),
                 "-o", str(output), str(project / "Entry.agda")],
                cwd=project, capture_output=True, text=True,
            )
            assert result.returncode == 0, (label, result.stdout, result.stderr)
            graph_path = output / ("graph.json" if mode == "lazy" else "deps.json")
            graph = json.loads(graph_path.read_text(encoding="utf-8"))
            expected_modules = (
                local_modules if no_externals else local_modules | external_modules
            )
            expected_files = {
                str(p) for p in sources
                if not no_externals or p.is_relative_to(project)
            }
            expected_map = {
                m: p for m, p in module_files.items() if m in expected_modules
            }
            expected_edges = {("Entry", "Local")}
            if not no_externals:
                expected_edges |= {("Entry", "Library"), ("Entry", "Unresolved")}

            assert set(graph["modules"]) == expected_modules, (label, graph["modules"])
            assert graph["entryModule"] == "Entry", label
            if mode == "expanded":
                assert graph["moduleFiles"] == expected_map, (label, graph["moduleFiles"])
                assert set(graph["sourceFiles"]) == expected_files, (label, graph["sourceFiles"])
                externals = set(graph["externalModules"])
                edges = {tuple(edge) for edge in graph["moduleEdges"]}
            else:
                assert set(graph["files"]) == expected_files, (label, graph["files"])
                decoded_map = {
                    m: graph["files"][i]
                    for m, i in zip(graph["modules"], int32s(graph["moduleToFile"]))
                    if i >= 0
                }
                assert decoded_map == expected_map, (label, decoded_map)
                externals = {
                    graph["modules"][i] for i in int32s(graph["externalModules"])
                }
                edges = {
                    (graph["modules"][s], graph["modules"][t])
                    for s, t in graph["moduleEdges"]
                }
                if mode == "lazy":
                    manifest = graph["moduleFiles"]
                    assert set(manifest) == expected_modules, (label, manifest)
                    for path in manifest.values():
                        json.loads((output / path).read_text(encoding="utf-8"))
                    detail_files = {
                        str(p.relative_to(output))
                        for p in (output / "modules").glob("*.json")
                    }
                    assert detail_files == set(manifest.values()), (label, detail_files)
            assert externals == (set() if no_externals else external_modules), (label, externals)
            assert edges == expected_edges, (label, edges)
    print("skip-agda metadata OK (expanded, packed, lazy; external and local scans)")


def main():
    if len(sys.argv) != 2:
        print("usage: skip_agda_check.py /path/to/agda-deps", file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="agda-deps-skip-") as tmp:
        check(binary, Path(tmp))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
