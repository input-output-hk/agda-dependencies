#!/usr/bin/env python3
"""Check physical project containment in normal, skip and incremental modes.

Usage: python3 schema/project_containment_check.py /path/to/agda-deps [old-binary]
The optional old binary seeds an incremental graph with the former prefix bug.
"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


def check(binary, root, previous=None):
    project = root / "project"
    sibling = root / "project-old"
    library = root / "library"
    for directory in (project / ".targets", sibling, library / ".targets"):
        directory.mkdir(parents=True)
    (project / "project.agda-lib").write_text("name: project\ninclude: .\n")
    (project / "Entry.agda").write_text(
        "module Entry where\n"
        "open import Local\nopen import Neighbor\n"
        "open import Incoming\nopen import Outgoing\n"
        "postulate\n"
        "  fromLocal : Local.X\n  fromNeighbor : Neighbor.X\n"
        "  fromIncoming : Incoming.X\n  fromOutgoing : Outgoing.X\n"
    )
    for module, path in {
        "Local": project / "Local.agda",
        "Neighbor": sibling / "Neighbor.agda",
        "Incoming": project / ".targets" / "Incoming.agda",
        "Outgoing": library / ".targets" / "Outgoing.agda",
    }.items():
        path.write_text(f"module {module} where\npostulate X : Set\n")
    outgoing = project / "Outgoing.agda"
    outgoing.symlink_to(library / ".targets" / "Outgoing.agda")
    (library / "Incoming.agda").symlink_to(project / ".targets" / "Incoming.agda")
    # Same contents, different physical location. Retargeting the symlink
    # must invalidate output even when Agda and the fragment cache stay warm.
    incoming_outgoing = project / ".targets" / "Outgoing.agda"
    incoming_outgoing.write_bytes(outgoing.read_bytes())

    tested_modules = {"Entry", "Local", "Neighbor", "Incoming", "Outgoing"}
    local_modules = {"Entry", "Local", "Incoming"}
    external_modules = {"Neighbor", "Outgoing"}

    def run(label, skip=False, no_externals=False, incremental=False, exe=binary):
        flags = []
        if skip:
            flags.append("--skip-agda")
        if no_externals:
            flags.append("--no-externals")
        if incremental:
            flags.append("--incremental")
        output = root / label
        result = subprocess.run(
            [str(exe), "--no-libraries", "--format=json", "--json-mode=expanded",
             *flags, "-i", str(project), "-i", str(sibling), "-i", str(library),
             "-o", str(output), str(project / "Entry.agda")],
            cwd=project, capture_output=True, text=True,
        )
        assert result.returncode == 0, (label, result.stdout, result.stderr)
        graph = json.loads((output / "deps.json").read_text(encoding="utf-8"))
        return graph, result.stderr

    def verify(graph, skip, no_externals, retargeted=False):
        local = local_modules | ({"Outgoing"} if retargeted else set())
        external = external_modules - ({"Outgoing"} if retargeted else set())
        expected = local if no_externals else tested_modules
        assert set(graph["modules"]) & tested_modules == expected, graph["modules"]
        assert set(graph["externalModules"]) & tested_modules == (
            set() if no_externals else external
        ), graph["externalModules"]
        assert set(graph["moduleFiles"]) <= set(graph["modules"]), graph["moduleFiles"]
        expected_edges = {("Entry", m) for m in expected - {"Entry"}}
        edges = {
            tuple(edge) for edge in graph["moduleEdges"]
            if set(edge) <= tested_modules
        }
        assert edges == expected_edges, edges
        if skip:
            if no_externals:
                # Keep the external spelling of Incoming, whose destination
                # is internal; discard the in-project spelling of Outgoing.
                files = set(graph["sourceFiles"])
                assert str(library / "Incoming.agda") in files, files
                assert (str(outgoing) in files) == retargeted, files
                assert str(sibling / "Neighbor.agda") not in files, files
        else:
            names = {d["name"] for d in graph["definitions"]}
            for module in tested_modules - {"Entry"}:
                assert (f"{module}.X" in names) == (module in expected), names
            if no_externals:
                summary = set(graph["externals_summary"]["modules"])
                assert summary & tested_modules == external, summary
                for source, target in graph["definitionEdges"]:
                    assert not any(target == f"{m}.X" for m in external), (source, target)

    for skip in (False, True):
        for no_externals in (False, True):
            label = f"{'skip' if skip else 'normal'}-{'local' if no_externals else 'all'}"
            graph, _ = run(label, skip=skip, no_externals=no_externals)
            verify(graph, skip, no_externals)

    # Warm main interfaces deliberately cannot seed a fragment, because they
    # lack dead-private recovery. Start this independent incremental check cold.
    for interface in project.rglob("Entry.agdai"):
        interface.unlink()
    if previous:
        old_graph, _ = run("incremental", no_externals=True, incremental=True, exe=previous)
        assert "Neighbor" in old_graph["modules"], "old binary did not reproduce prefix bug"
    graph, log = run("incremental", no_externals=True, incremental=True)
    verify(graph, False, True)
    if previous:
        assert all(f"fragment hit for '{m}'" in log for m in tested_modules), log
        assert "skipped re-emit" not in log, log
    graph, log = run("incremental", no_externals=True, incremental=True)
    verify(graph, False, True)
    assert "skipped re-emit" in log, log

    outgoing.unlink()
    outgoing.symlink_to(incoming_outgoing)
    graph, log = run("incremental", no_externals=True, incremental=True)
    verify(graph, False, True, retargeted=True)
    assert all(f"fragment hit for '{m}'" in log for m in tested_modules), log
    assert "skipped re-emit" not in log, log
    graph, log = run("incremental", no_externals=True, incremental=True)
    verify(graph, False, True, retargeted=True)
    assert "skipped re-emit" in log, log
    graph, _ = run("skip-retargeted", skip=True, no_externals=True)
    verify(graph, True, True, retargeted=True)
    print("project containment OK (sibling prefixes, symlinks, normal/skip, incremental)")


def main():
    if len(sys.argv) not in (2, 3):
        print("usage: project_containment_check.py /path/to/agda-deps [old-binary]",
              file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve(strict=True)
    previous = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) == 3 else None
    with tempfile.TemporaryDirectory(prefix="agda-deps-containment-") as tmp:
        check(binary, Path(tmp), previous)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
