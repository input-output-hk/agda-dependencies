#!/usr/bin/env python3
"""General-clause evidence, default compatibility, contexts and capture guards."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from type_terms_check import validate_evidence


def main():
    binary = str(Path(sys.argv[1]).resolve())
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="agda-term-evidence-") as raw:
        temp = Path(raw)
        source = temp / "term-evidence.agda"
        shutil.copyfile(repo / "test-hardening/term-evidence.agda", source)
        def run(flags, name, ok=True):
            output = temp / name
            result = subprocess.run([binary, "--quiet", "--format=json", "--json-mode=expanded", "--no-externals", *flags,
                                     "-i", str(temp), "-o", str(output), str(source)],
                                    capture_output=True, text=True, timeout=90, cwd=temp)
            assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
            return json.loads((output / "deps.json").read_text()) if ok else result
        baseline = run(["--with-type-terms"], "baseline")
        # Graph extraction already has a documented cold/warm distinction for
        # generated private projections. Compare the same cold pipeline here.
        for interface in temp.rglob('*.agdai'): interface.unlink()
        graph = run(["--with-type-terms", "--with-terms", "--term-scope=term-evidence"], "terms")
        assert "termEvidence" not in baseline
        assert {k: v for k, v in graph.items() if k != "termEvidence"} == baseline, [k for k in baseline if baseline[k]!=graph.get(k)]
        data = graph["termEvidence"]
        assert data["v"] == 1
        defs = {d["name"]: d for d in data["definitions"]}
        auxiliary = {d["name"]: d for d in data["auxiliaryDefinitions"]}
        assert not (set(auxiliary) & {d["name"] for d in graph["definitions"]})
        nodes = data["nodes"]
        adapter = {"nodes": nodes, "definitions": [dict(d, bodies=[{"root": c["body"], "context": c["context"]}
                   for c in d["clauses"] if c["body"] is not None]) for d in list(defs.values())+list(auxiliary.values())]}
        validate_evidence(adapter)
        assert defs["term-evidence.shift"]["clauses"][0]["body"] is not None
        assert defs["term-evidence.postulate-free-proof"]["clauses"][0]["body"] is not None
        assert defs["term-evidence.Section.compute"]["sectionParameters"] == 1
        assert any(d["projectionIndex"] for d in defs.values())
        assert any(d["constructorParameters"] is not None for d in defs.values())
        tags=set()
        def patterns(ps):
            for p in ps:
                tags.add(p['tag']);patterns(p['children'])
        for d in list(defs.values())+list(auxiliary.values()):
            for c in d['clauses']: patterns(c['patterns'])
        assert {'var','con','dot','absurd','lit'} <= tags, tags
        assert defs['term-evidence.absurd']['clauses'][0]['body'] is None
        assert auxiliary, "generated with-helper evidence is missing"
        assert all(not c["unfolding"] for d in list(defs.values())+list(auxiliary.values()) for c in d["clauses"])
        annotations = data["occurrenceTypes"]
        assert annotations and all(a["path"] == [] for a in annotations)
        by_name = defs | auxiliary
        for a in annotations:
            clause = by_name[a["definition"]]["clauses"][a["clause"]]
            assert a["type"] == clause["resultType"] and a["context"] == clause["context"]
            assert a["environment"] in data["environment"]
        coverage = data["coverage"][0]
        assert coverage["scopes"] == ["term-evidence"]
        assert coverage["occurrenceTyping"] == "clause-roots-and-bounded-neutral-subterms"
        assert data["subtermTypes"], "missing bounded contextual subterm types"
        counts = {}
        for a in data["subtermTypes"]:
            clause = by_name[a["definition"]]["clauses"][a["clause"]]
            assert a["path"] and a["context"] == clause["context"]
            root = clause["body"]
            for index in a["path"]:
                node = nodes[root]
                assert not (node["binds"] and (node["tag"] == "lam" or node["tag"] == "pi" and index == 1))
                root = node["children"][index]
            key = (a["definition"], a["clause"])
            counts[key] = counts.get(key, 0) + 1
        assert max(counts.values()) <= coverage["subtermTypeLimit"]
        assert coverage["subtermTypingComplete"] is False
        assert all(name.startswith("term-evidence.") for name in coverage["selectedRoots"])
        warm = run(["--with-terms", "--term-scope=term-evidence"], "warm")["termEvidence"]
        assert {d['name'] for d in warm['definitions']} >= {'term-evidence.shift','term-evidence.map','term-evidence.projected'}
        assert warm['occurrenceTypes']
        empty = run(["--with-terms", "--term-scope=Absent"], "empty")["termEvidence"]
        assert not empty["definitions"] and not empty["auxiliaryDefinitions"]
        for flags in (["--incremental"], ["--skip-agda"], ["--json-mode=packed"]):
            result = run(["--with-terms", *flags], "invalid", False)
            assert "--with-terms requires" in result.stderr
        config = temp / "options.yml"
        config.write_text("format: json\njson-mode: expanded\nwith-terms: true\nterm-scope: [term-evidence]\n")
        assert warm == run(["--config", str(config)], "yaml")["termEvidence"]
        config.write_text("with-terms: true\nincremental: true\n")
        doctor = subprocess.run([binary, "doctor", "--config", str(config)],capture_output=True,text=True)
        assert doctor.returncode != 0 and "with-terms" in doctor.stdout
        # A registered dependency nested inside an owned include remains
        # read-only, including when Agda uses an explicit library registry.
        owned = temp / "owned"
        vendor = owned / "vendor"
        (vendor / "src").mkdir(parents=True)
        (owned / "project.agda-lib").write_text("name: owned\ninclude: . vendor/src\ndepend: patterns\n")
        library = vendor / "patterns.agda-lib"
        library.write_text("name: patterns\ninclude: src\n")
        registry = temp / "libraries"
        registry.write_text(str(library) + "\n")
        (vendor / "src/Vendor.agda").write_text("module Vendor where\ndata T : Set where\n  unit : T\n")
        main_source = owned / "Owned.agda"
        main_source.write_text("module Owned where\nopen import Vendor\nkeep : T\nkeep = unit\n")
        output = temp / "ownership"
        result = subprocess.run([binary, "--quiet", "--format=json", "--json-mode=expanded", "--with-terms",
            "--library-file", str(registry), "-o", str(output), str(main_source)], cwd=owned,
            capture_output=True, text=True, timeout=90)
        assert result.returncode == 0, (result.stdout, result.stderr)
        evidence = json.loads((output / "deps.json").read_text())["termEvidence"]
        for environment in evidence["environment"].values():
            ownership = environment["sourceOwnership"]
            assert ownership["moduleRoles"]["Owned"] == "project"
            assert ownership["moduleRoles"]["Vendor"] == "library"
            assert str(vendor / "src") in ownership["libraryRoots"]
            assert not ownership["warnings"]
    print("termEvidence: clauses, contexts, helper closure, options and unchanged typeTerms passed")

if __name__ == "__main__":
    main()
