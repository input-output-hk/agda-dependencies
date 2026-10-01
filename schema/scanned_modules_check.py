#!/usr/bin/env python3
"""Check source-only module inventory across JSON shapes and incremental runs.

Usage: scanned_modules_check.py /path/to/agda-deps [old-binary]
The optional old binary seeds packed output missing isolated scanned modules.
All sources, interfaces, caches and output live in a temporary directory.
"""

import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def int32s(value):
    raw = base64.b64decode(value)
    return struct.unpack(f"<{len(raw) // 4}i", raw)


def check(binary, root, previous=None):
    project = root / "project"
    library = root / "library"
    for directory in (project / "LocalOnly", library / "Unused", root / "registry"):
        directory.mkdir(parents=True)
    (project / "project.agda-lib").write_text("name: project\ninclude: .\n")
    config = root / "empty.yml"
    config.write_text("{}\n")
    env = dict(os.environ, AGDA_DIR=str(root / "registry"))
    env.pop("AGDA_DEPS_CONFIG", None)

    # Empty or unimported sources must appear without being type-checked or
    # contributing fabricated definition nodes. The unresolved names in the
    # isolated sources make accidental type-checking observable.
    module_sources = {
        "Entry": (project / "Entry.agda", "open import Hub\nopen import Used\n"
                  "postulate local : Set\n"),
        "Hub": (project / "Hub.agda", "open import Base public\n"),
        "Base": (project / "Base.agda", "postulate X : Set\n"),
        "Used": (library / "Used.agda", "postulate X : Set\n"),
        "LocalOnly": (project / "LocalOnly.agda", ""),
        "LocalOnly.Child": (project / "LocalOnly" / "Child.agda", ""),
        "LocalDefs": (project / "LocalDefs.agda", "bad : MissingName\n"),
        "Unused": (library / "Unused.agda", ""),
        "Unused.Child": (library / "Unused" / "Child.agda", ""),
        "ExternalDefs": (library / "ExternalDefs.agda", "bad : MissingName\n"),
    }
    for module, (path, body) in module_sources.items():
        path.write_text(f"module {module} where\n{body}", encoding="utf-8")
    no_headers = {project / "NoHeader.agda", library / "NoHeader.agda"}
    for path in no_headers:
        path.write_text("-- No module declaration.\n", encoding="utf-8")

    tested = set(module_sources)
    external = {m for m, (p, _) in module_sources.items() if not p.is_relative_to(project)}
    scanned_files = {str(p) for p, _ in module_sources.values()} | {str(p) for p in no_headers}
    source_only = tested - {"Entry", "Hub", "Base", "Used"}
    cache = root / "cache"

    def run(label, mode="expanded", skip=False, no_externals=False, excludes=(),
            incremental=False, exe=binary):
        output = root / label
        flags = [f"--exclude={m}" for m in excludes]
        if skip:
            flags.append("--skip-agda")
        if no_externals:
            flags.append("--no-externals")
        if mode == "lazy":
            flags.append("--lazy")
        if incremental:
            flags += ["--incremental", "--cache-dir", str(cache)]
        result = subprocess.run(
            [str(exe), "--config", str(config), "--no-libraries", "--format=json",
             f"--json-mode={'packed' if mode == 'lazy' else mode}",
             "--packed-analytical", "--with-signatures", "--with-term-hashes",
             *flags, "-i", str(project), "-i", str(library), "-o", str(output),
             str(project / "Entry.agda")],
            cwd=project, env=env, capture_output=True, text=True,
        )
        assert result.returncode == 0, (label, result.stdout, result.stderr)
        path = output / ("graph.json" if mode == "lazy" else "deps.json")
        return json.loads(path.read_text(encoding="utf-8")), result.stderr, path

    def verify(graph, path, mode="expanded", skip=False, no_externals=False, excludes=()):
        expected = {
            m for m in tested if not (no_externals and m in external)
            and not any(m == prefix or m.startswith(prefix + ".") for prefix in excludes)
        }
        modules = set(graph["modules"])
        assert modules & tested == expected, (mode, expected, modules)
        expected_map = {m: str(module_sources[m][0]) for m in expected}
        expected_files = {
            p for p in scanned_files if not no_externals or Path(p).is_relative_to(project)
        }
        if mode == "expanded":
            mapping = graph["moduleFiles"]
            assert set(mapping) <= modules, mapping
            assert set(graph["sourceFiles"]) == expected_files, graph["sourceFiles"]
            externals = set(graph["externalModules"])
            edges = {tuple(e) for e in graph["moduleEdges"]}
            names = {d["name"] for d in graph["definitions"]}
        else:
            mapping = {
                m: graph["files"][i]
                for m, i in zip(graph["modules"], int32s(graph["moduleToFile"])) if i >= 0
            }
            assert set(graph["files"]) & scanned_files == expected_files, graph["files"]
            if no_externals:
                assert all(Path(p).is_relative_to(project) for p in graph["files"]), graph["files"]
            externals = {graph["modules"][i] for i in int32s(graph["externalModules"])}
            edges = {(graph["modules"][s], graph["modules"][t]) for s, t in graph["moduleEdges"]}
            if mode == "lazy":
                manifest = graph["moduleFiles"]
                assert set(manifest) == modules, manifest
                names = set()
                for module, filename in manifest.items():
                    detail = json.loads((path.parent / filename).read_text(encoding="utf-8"))
                    names.update(detail["defs"]["names"])
                    if module in source_only & expected or module == "Hub" or skip:
                        assert detail["placeholder"] is True, (module, detail)
                        assert detail["defs"]["names"] == [], (module, detail)
                        if not skip:
                            assert int32s(detail["defs"]["lines"]) == (), (module, detail)
                        assert detail["reason"] == (
                            "external" if module in externals else "filtered"
                        ), (module, detail)
            else:
                names = set(graph["defs"]["names"])
        assert {m: p for m, p in mapping.items() if m in tested} == expected_map, mapping
        assert externals <= modules, externals
        assert externals & tested == expected & external, externals
        assert all(s in modules and t in modules for s, t in edges), edges
        expected_edges = {("Entry", "Hub"), ("Hub", "Base")}
        if not no_externals:
            expected_edges.add(("Entry", "Used"))
        assert {e for e in edges if set(e) <= tested} == expected_edges, edges
        assert not any(n.startswith(m + ".") for n in names for m in source_only), names
        if skip:
            assert names == set(), names
        else:
            assert {"Entry.local", "Base.X"} <= names, names
            assert ("Used.X" in names) == (not no_externals), names

    # Exercise both producers, every output shape, and the composed filters.
    for skip in (False, True):
        for mode in ("expanded", "packed", "lazy"):
            for no_externals in (False, True):
                for excludes in ((), ("Unused", "LocalOnly")):
                    label = f"{skip}-{mode}-{no_externals}-{bool(excludes)}"
                    graph, _, path = run(label, mode, skip, no_externals, excludes)
                    verify(graph, path, mode, skip, no_externals, excludes)

    # Start cold so the main module can seed its fragment. An older binary's
    # serialized packed graph must refresh while extracted fragments survive.
    for interface in project.rglob("Entry.agdai"):
        interface.unlink()
    if previous:
        old, _, _ = run("incremental", mode="packed", incremental=True, exe=previous)
        assert "Unused" not in old["modules"], "old binary did not reproduce omission"
        before_fragments = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in cache.glob("*.frag")}
    graph, log, path = run("incremental", mode="packed", incremental=True)
    verify(graph, path, mode="packed")
    if previous:
        assert "skipped re-emit" not in log, log
        assert "fragment hit for 'Entry'" in log, log
        assert before_fragments == {p: (p.read_bytes(), p.stat().st_mtime_ns)
                                    for p in cache.glob("*.frag")}

    def unchanged(mode):
        graph, _, path = run(f"incremental-{mode}", mode=mode, incremental=True)
        verify(graph, path, mode=mode)
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        graph, log, path = run(f"incremental-{mode}", mode=mode, incremental=True)
        verify(graph, path, mode=mode)
        assert "skipped re-emit" in log, log
        assert before == (path.read_bytes(), path.stat().st_mtime_ns)

    for mode in ("expanded", "packed", "lazy"):
        unchanged(mode)
    added = library / "Added.agda"
    added.write_text("module Added where\n", encoding="utf-8")
    for mode in ("expanded", "packed", "lazy"):
        graph, log, path = run(f"incremental-{mode}", mode=mode, incremental=True)
        assert "Added" in graph["modules"], (mode, graph["modules"])
        assert "skipped re-emit" not in log and "fragment hit for 'Entry'" in log, log
        if mode == "lazy":
            detail = json.loads((path.parent / graph["moduleFiles"]["Added"]).read_text())
            assert detail["placeholder"] and detail["reason"] == "external", detail
    added.unlink()
    for mode in ("expanded", "packed", "lazy"):
        graph, log, path = run(f"incremental-{mode}", mode=mode, incremental=True)
        verify(graph, path, mode=mode)
        assert "Added" not in graph["modules"], (mode, graph["modules"])
        assert "skipped re-emit" not in log and "fragment hit for 'Entry'" in log, log
    print("scanned module inventory OK (normal/skip, expanded/packed/lazy, filters, incremental)")


def main():
    if len(sys.argv) not in (2, 3):
        print("usage: scanned_modules_check.py /path/to/agda-deps [old-binary]", file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve(strict=True)
    previous = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) == 3 else None
    with tempfile.TemporaryDirectory(prefix="agda-deps-scanned-modules-") as tmp:
        check(binary, Path(tmp), previous)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
