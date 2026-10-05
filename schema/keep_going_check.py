#!/usr/bin/env python3
"""Check keep-going's complete sweep, hole state and option isolation.

Usage: python3 schema/keep_going_check.py /path/to/agda-deps
"""
import base64
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


binary = Path(sys.argv[1]).resolve()


def int32s(encoded):
    data = base64.b64decode(encoded)
    return struct.unpack(f"<{len(data) // 4}i", data)


with tempfile.TemporaryDirectory(prefix="agda-deps-keep-going-") as temporary:
    root = Path(temporary)
    project = root / "project"
    external = root / "external"
    project.mkdir()
    external.mkdir()
    files = {
        "Entry.agda": "module Entry where\nopen import Good\nopen import Bad\nopen import Later\n",
        "HealthyEntry.agda": "module HealthyEntry where\nopen import Good\n",
        "Good.agda": "module Good where\nopen import Agda.Builtin.Nat public\n"
                     "double : Nat → Nat\ndouble n = n + n\n"
                     "quadruple : Nat → Nat\nquadruple n = double (double n)\n"
                     "withHelper : Nat → Nat\nwithHelper n = helper n\n"
                     "  where\n    helper : Nat → Nat\n    helper _ = zero\n",
        "Bad.agda": "module Bad where\nopen import Good\nbad : Nat\nbad = Set\n",
        "Later.agda": "module Later where\nopen import Good\nlater : Nat\nlater = double 2\n",
        "Orphan.agda": "module Orphan where\nopen import Agda.Builtin.Nat\n"
                       "private\n  hidden : Nat\n  hidden = 0\n"
                       "visible : Nat\nvisible = 1\n",
        "Holey.agda": "{-# OPTIONS --allow-unsolved-metas #-}\nmodule Holey where\n"
                      "open import Agda.Builtin.Nat\nhole : Nat\nhole = ?\n",
        "Silent.agda": "{-# OPTIONS --allow-unsolved-metas #-}\nmodule Silent where\n"
                       "open import Agda.Builtin.Nat\nrecord Pair : Set where\n"
                       "  field first second : Nat\npair : Pair\n"
                       "pair = record { first = 0 }\n",
        # A later root must not inherit allow-unsolved-metas from Silent.
        "Untolerated.agda": "module Untolerated where\nopen import Agda.Builtin.Nat\n"
                            "hole : Nat\nhole = ?\n",
        "Undefined.agda": "module Undefined where\nopen import Good\n"
                          "bad : Nat\nbad = absentDefinition\n",
        "Bodyless.agda": "module Bodyless where\npostulate N : Set\nmissingBody : N\n",
        "MissingImport.agda": "module MissingImport where\nimport Nonexistent\n",
        "Blocked.agda": "module Blocked where\nopen import Bad\n",
        "ParseBroken.agda": "module ParseBroken where\nx :\n",
        "CycleA.agda": "module CycleA where\nimport CycleB\n",
        "CycleB.agda": "module CycleB where\nimport CycleA\n",
        # Checking candidates must not depend on the scanner finding a header.
        "Implicit.agda": "postulate X : Set\n",
        "Literate.lagda.md": "Some prose.\n```agda\nmodule Literate where\n"
                             "postulate X : Set\n```\n",
        "Excluded.agda": "module Excluded where\npostulate X : Set\n",
    }
    for name, source in files.items():
        (project / name).write_text(source, encoding="utf-8")
    (external / "ExternalUnused.agda").write_text(
        "module ExternalUnused where\npostulate N : Set\nbad : N\nbad = Set\n",
        encoding="utf-8",
    )
    # Physical containment also excludes a project spelling of an external file.
    (project / "ExternalUnused.agda").symlink_to(external / "ExternalUnused.agda")

    failed = {"Entry", "Bad", "Blocked", "Bodyless", "MissingImport", "ParseBroken",
              "CycleA", "CycleB", "Undefined", "Untolerated"}
    expected = {"Good.double", "Good.quadruple", "Later.later", "Orphan.visible",
                "Holey.hole", "Silent.pair", "Implicit.X", "Literate.X"}

    def cold():
        for interface in project.rglob("*.agdai"):
            interface.unlink()

    def run(label, flags, entry="Entry.agda", mode="expanded", succeeds=True):
        output = root / label
        args = [str(binary), "--no-libraries", "--format=json",
                "--json-mode=" + ("packed" if mode == "lazy" else mode),
                "--no-externals", "--with-signatures", "--with-term-hashes",
                "--exclude=Excluded", "-i", str(project), "-i", str(external),
                "-o", str(output), *flags, str(project / entry)]
        if mode != "expanded":
            args.append("--packed-analytical")
        if mode == "lazy":
            args.append("--lazy")
        result = subprocess.run(args, cwd=project, capture_output=True, text=True, timeout=60)
        path = output / ("graph.json" if mode == "lazy" else "deps.json")
        if not succeeds:
            assert result.returncode != 0, (label, result.stdout, result.stderr)
            assert not path.exists(), path
            return None, output, result.stdout + result.stderr
        assert result.returncode == 0, (label, result.stdout, result.stderr)
        return json.loads(path.read_text(encoding="utf-8")), output, result.stderr

    def verify(graph, output, mode, private=False, entry=None):
        if mode == "expanded":
            definitions = {d["name"]: d for d in graph["definitions"]}
            errors = set(graph["failedModules"])
            edges = {tuple(e) for e in graph["definitionEdges"]}
        else:
            errors = {module for module, state in
                      zip(graph["modules"], base64.b64decode(graph["moduleStates"])) if state}
            definitions = {}
            details = ([json.loads((output / file).read_text(encoding="utf-8"))
                        for file in graph["moduleFiles"].values()] if mode == "lazy" else [graph])
            for detail in details:
                defs = detail["defs"]
                if not defs["names"]:
                    continue
                states = struct.unpack(f"<{len(defs['names'])}b", base64.b64decode(defs["states"]))
                counts = int32s(defs["unsolvedMetas"])
                definitions.update({name: {"state": {0: "D", 1: "P", 2: "H", 3: "F"}[state],
                                           "unsolvedMetas": count, "type": typ}
                                    for name, state, count, typ in
                                    zip(defs["names"], states, counts, defs["types"])})
            edges = None
        assert errors == failed, (errors, failed)
        assert graph["entryModule"] == entry, graph["entryModule"]
        assert expected <= definitions.keys(), (expected - definitions.keys(), definitions)
        assert "Excluded" not in graph["modules"]
        assert not any(name.startswith("ExternalUnused.") for name in definitions)
        assert definitions["Holey.hole"]["state"] == "H", definitions["Holey.hole"]
        assert definitions["Holey.hole"].get("unsolvedMetas", 0) == 0
        assert definitions["Silent.pair"]["state"] == "H", definitions["Silent.pair"]
        assert definitions["Silent.pair"]["unsolvedMetas"] == 1
        assert graph["unsolvedModules"] == {"Silent": {"metas": [7], "constraints": []}}
        assert definitions["Good.quadruple"].get("type")
        assert not any(name.startswith(module + ".") for name in definitions for module in failed)
        if edges is not None:
            assert ("Good.quadruple", "Good.double") in edges
            assert ("Later.later", "Good.double") in edges
            helper = next(d for n, d in definitions.items() if n.startswith("Good.helper@"))
            assert helper["argUsage"]["arity"] == 1, helper
            assert helper["argUsage"]["removable"] == [0], helper
        if private:
            assert "Orphan.hidden" in definitions, definitions

    # Normal checking still aborts on a type error without writing a graph.
    cold()
    run("ordinary", [], succeeds=False)

    # Keep-going recovers roots after the failure and isolated roots. Repeat
    # warm to catch assumptions that every successful check leaves live state.
    for mode in ("expanded", "packed", "lazy"):
        cold()
        graph, output, _ = run("cold-" + mode, ["--keep-going"], mode=mode)
        verify(graph, output, mode, private=True)
        graph, output, _ = run("warm-" + mode, ["--keep-going"], mode=mode)
        verify(graph, output, mode)

    subprocess.run([sys.executable, str(Path(__file__).with_name("packed_analytical_check.py")),
                    str(root / "cold-packed" / "deps.json"),
                    str(root / "cold-expanded" / "deps.json"), str(root / "cold-lazy")],
                   check=True, timeout=30)

    # A successful entry retains its identity even when other roots fail.
    graph, output, _ = run("healthy-entry", ["--keep-going"], entry="HealthyEntry.agda")
    verify(graph, output, "expanded", entry="HealthyEntry")

    graph, output, _ = run("type-terms", ["--keep-going", "--with-type-terms"])
    verify(graph, output, "expanded")
    assert graph["typeTerms"]["v"] == 1, graph.get("typeTerms")

    config = root / "recovery.yml"
    config.write_text("keep-going: true\nincremental: true\n")
    graph, output, stderr = run("config", ["--config=" + str(config)])
    verify(graph, output, "expanded")
    assert "--incremental is disabled" in stderr, stderr
    assert not (output / ".agda-deps-cache").exists()
    doctor = subprocess.run([str(binary), "doctor", "--config=" + str(config)],
                            cwd=project, capture_output=True, text=True, timeout=30)
    assert doctor.returncode == 0, (doctor.stdout, doctor.stderr)
    assert "keep-going" in doctor.stdout and "incremental" in doctor.stdout, doctor.stdout

    config.write_text("keep-going: false\n")
    graph, output, _ = run("cli-over-config", ["--config=" + str(config), "--keep-going"])
    verify(graph, output, "expanded")

    # The sweep has one flag; the removed spelling must not remain an alias.
    _, _, diagnostic = run("removed-flag", ["--check-all"], succeeds=False)
    assert "check-all" in diagnostic, diagnostic

print("keep-going complete-source recovery OK")
