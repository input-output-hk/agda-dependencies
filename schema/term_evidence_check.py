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
        assert all(env["compilerBuiltins"]["EQUALITY"] == ["Agda.Builtin.Equality._≡_"]
                   for env in data["environment"].values())
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
        empty_constructor = next(d for d in (defs | auxiliary).values() if d['name'].endswith('.ConstructorSection.EmptyRecord.constructor'))
        assert empty_constructor['sectionParameters'] == empty_constructor['constructorParameters'] == 2
        tags=set()
        def patterns(ps):
            for p in ps:
                tags.add(p['tag']);patterns(p['children'])
        for d in list(defs.values())+list(auxiliary.values()):
            for c in d['clauses']: patterns(c['patterns'])
        assert {'var','con','dot','absurd','lit'} <= tags, tags
        assert defs['term-evidence.absurd']['clauses'][0]['body'] is None
        assert auxiliary, "generated with-helper evidence is missing"
        generated = [d for d in auxiliary.values() if d["sourceKind"] == "with-function"]
        assert generated and any(d["sourceParent"] == "term-evidence.select" for d in generated)
        assert all(d["sourceParent"] in defs or d["sourceParent"] in auxiliary for d in generated)
        assert defs["term-evidence.shift"]["sourceKind"] == "declaration"
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
        assert data["coverage"][0]["subtermQueryMicros"] == 100000
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
        # A valid annotation in Agda's complete clause may lie beyond the
        # serialized body's node limit. It must be omitted, never emitted as
        # a dangling path into the bounded evidence tree.
        original_source = source
        source = temp / "oversized.agda"
        source.write_text("module oversized where\nopen import Agda.Builtin.Nat\nlarge : Nat → Nat\nlarge n = " +
                          "suc (" * 5100 + "n" + ")" * 5100 + "\n")
        bounded = run(["--with-terms"], "bounded")["termEvidence"]
        source = original_source
        assert "capture-node-limit" in bounded["coverage"][0]["unsupportedReasons"]
        bounded_defs = {d["name"]: d for d in bounded["definitions"] + bounded["auxiliaryDefinitions"]}
        for annotation in bounded["subtermTypes"]:
            clause = bounded_defs[annotation["definition"]]["clauses"][annotation["clause"]]
            root = clause["body"]
            for index in annotation["path"]:
                children = bounded["nodes"][root]["children"]
                assert 0 <= index < len(children), "dangling bounded-body annotation"
                root = children[index]
        assert max(counts.values()) <= coverage["subtermTypeLimit"]
        assert coverage["subtermTypingComplete"] is False
        assert all(name.startswith("term-evidence.") for name in coverage["selectedRoots"])
        # Compatibility-generated clauses mention compiler interval postulates;
        # consumers need the actual bindings to distinguish these foundations
        # from ordinary source postulates, without a module-name whitelist.
        source = temp / "Cubical.agda"
        source.write_text("{-# OPTIONS --safe --cubical-compatible #-}\nmodule Cubical where\n"
                          "open import Agda.Builtin.Equality\n"
                          "cong : {A B : Set} (f : A → B) {x y : A} → x ≡ y → f x ≡ f y\n"
                          "cong f refl = refl\n")
        cubical = run(["--with-terms"], "cubical")["termEvidence"]
        for env in cubical["environment"].values():
            assert {k: env["compilerBuiltins"][k] for k in ["ISONE", "ISONE1", "ISONE2"]} == {
                "ISONE": ["Agda.Primitive.Cubical.IsOne"],
                "ISONE1": ["Agda.Primitive.Cubical.IsOne1"],
                "ISONE2": ["Agda.Primitive.Cubical.IsOne2"]}
        source = original_source
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
