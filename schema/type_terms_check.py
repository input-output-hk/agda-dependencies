#!/usr/bin/env python3
"""Optional typeTerms wire contract, structural regressions and CLI guards."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def validate_evidence(data):
    # Match the consumer's arity and section-telescope validation: unsupported
    # evidence must still be a well-formed DAG that the consumer can traverse.
    arities = {"var": 0, "def": 0, "con": 0, "lit": 0, "app": 2, "pi": 2,
               "lam": 1, "type": 2, "binder": 1, "proj": 1, "irrelevant": 1,
               "unsupported": 0, "level-plus": 1, "sort": 1, "sort-inf": 0,
               "sort-constant": 0}
    nodes = data["nodes"]
    for i, node in enumerate(nodes):
        tag = node["tag"]
        assert tag == "level" or tag in arities, node
        if tag in arities:
            assert len(node["children"]) == arities[tag], node
        assert all(0 <= child < i for child in node["children"]), node
        assert not node["binds"] or tag in {"pi", "lam"}, node
        assert len(node["info"]) == (4 if tag in {"app", "pi", "lam", "binder"} else 0)
    for definition in data["definitions"]:
        root = definition["signature"]
        assert 0 <= root < len(nodes) and definition["sectionParameters"] >= 0
        remaining = definition["sectionParameters"]
        while remaining:
            node = nodes[root]
            if node["tag"] == "type":
                root = node["children"][0]
            else:
                assert node["tag"] == "pi", definition
                root = node["children"][1]
                remaining -= 1
        for body in definition["bodies"]:
            assert 0 <= body["root"] < len(nodes)
            assert all(0 <= c < len(nodes) and nodes[c]["tag"] == "binder"
                       for c in body["context"])


def main():
    binary = str(Path(sys.argv[1]).resolve())
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="agda-type-terms-") as raw:
        temp = Path(raw)
        source = temp / "type-terms.agda"
        shutil.copyfile(repo / "test-hardening/type-terms.agda", source)

        def run(flags, name, ok=True, fixture=source):
            output = temp / name
            result = subprocess.run(
                [binary, "--quiet", "--format=json", "--json-mode=expanded",
                 "--with-signatures", "--no-externals", *flags,
                 "-i", str(fixture.parent), "-o", str(output), str(fixture),
                 "+RTS", "-N1", "-RTS"],
                capture_output=True, text=True, timeout=60, cwd=fixture.parent,
            )
            assert (result.returncode == 0)==ok, (result.returncode, result.stdout, result.stderr)
            return json.loads((output / "deps.json").read_text()) if ok else result
        old = run([], "without")
        assert "typeTerms" not in old
        graph = run(["--with-type-terms"], "with")
        data = graph["typeTerms"]
        assert graph["v"]==2 and graph["nodeKeyVersion"]==3 and data["v"]==1
        assert {d["name"] for d in data["definitions"]} <= {d["name"] for d in graph["definitions"]}
        assert any(d["name"]=="type-terms.AtLeast≥" and d["bodies"] for d in data["definitions"]), [(d["name"],len(d["bodies"])) for d in data["definitions"]]
        validate_evidence(data)
        quoted = {n["name"] for n in data["nodes"] if n["tag"] == "lit" and n["name"].startswith("LitQName ")}
        local = next(d["name"] for d in data["definitions"] if ".local@" in d["name"])
        assert quoted == {"LitQName Agda.Builtin.Nat.Nat", "LitQName " + local}, quoted
        # A cold copy at a different source path must have identical structural
        # evidence, including quoted anonymous-section names with canonical keys.
        relocated = temp / "relocated" / source.name
        relocated.parent.mkdir()
        shutil.copyfile(source, relocated)
        relocated_data = run(["--with-type-terms"], "relocated-output", fixture=relocated)["typeTerms"]
        assert data["nodes"] == relocated_data["nodes"]
        assert [{k: v for k, v in d.items() if k != "file"} for d in data["definitions"]] == [
            {k: v for k, v in d.items() if k != "file"} for d in relocated_data["definitions"]]
        # Both runs use warm Agda interfaces; the field must be populated again.
        assert data==run(["--with-type-terms"], "again")["typeTerms"]
        for flags in [["--incremental"],["--skip-agda"],["--json-mode=packed"]]:
            bad=run(["--with-type-terms",*flags], "bad",False)
            assert "--with-type-terms requires" in bad.stderr
        config=temp / "options.yml"
        config.write_text("format: json\njson-mode: expanded\nwith-type-terms: true\n")
        assert run(["--config",str(config)], "yaml")["typeTerms"]==data
        config.write_text("with-type-terms: true\nincremental: true\n")
        doctor=subprocess.run([binary,"doctor","--config",str(config)],capture_output=True,text=True)
        assert doctor.returncode!=0 and "with-type-terms" in doctor.stdout
        for name in ("type-terms-cohesion", "type-terms-bodyless"):
            fixture = temp / name / (name + ".agda")
            fixture.parent.mkdir()
            shutil.copyfile(repo / "test-hardening" / fixture.name, fixture)
            # Exercise capture on a cold interface before the default run.
            evidence = run(["--with-type-terms"], name + "-with", fixture=fixture)["typeTerms"]
            baseline = run([], name + "-without", fixture=fixture)
            validate_evidence(evidence)
            definitions = {d["name"]: d for d in evidence["definitions"]}
            assert set(definitions) == {d["name"] for d in baseline["definitions"]}
            if name.endswith("cohesion"):
                nodes = evidence["nodes"]
                for key, count in ((name + ".Flat.value", 1), (name + ".Flat.Nested.nested", 2)):
                    definition = definitions[key]
                    assert definition["sectionParameters"] == count, definition
                    pi = nodes[nodes[definition["signature"]]["children"][0]]
                    assert pi["tag"] == "pi" and pi["binds"], pi
                    assert nodes[pi["children"][0]]["tag"] == "unsupported", pi
            else:
                for key in (name + ".p", name + ".absurd"):
                    assert definitions[key]["bodies"] == [], definitions[key]
                nodes = evidence["nodes"]
                signature = definitions[name + ".p"]["signature"]
                assert nodes[nodes[signature]["children"][0]]["name"] == name + ".T"
    print("typeTerms: wire, section binders, bodyless aliases, quoted names, warm interfaces and CLI/config guards passed")


if __name__=="__main__":
    main()
