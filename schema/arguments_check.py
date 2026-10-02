#!/usr/bin/env python3
"""Check startup argv semantics against both normal and skip-mode behavior.

Usage: python3 schema/arguments_check.py /path/to/agda-deps
Uses temporary projects and an isolated Agda library registry.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(binary, root):
    caller = root / "caller"
    project = root / "project"
    src = project / "src"
    extra = project / "extra"
    registry = root / "registry"
    for directory in (caller, src, extra, registry):
        directory.mkdir(parents=True)
    (project / "project.agda-lib").write_text("name: project\ninclude: src\n")
    (src / "Entry.agda").write_text("module Entry where\ndata Unit : Set where\n  unit : Unit\n")
    (extra / "Unused.agda").write_text("module Unused where\n")
    lib = extra / "fixture.agda-lib"
    lib.write_text("name: fixture-library\ninclude: .\n")
    (registry / "libraries").write_text(str(lib) + "\n")
    good_config = "format: json\njson-mode: expanded\n"
    (caller / "chosen.yml").write_text(good_config)
    (caller / "--help").write_text(good_config)
    (project / "chosen.yml").write_text("format: dot\n")
    (project / ".agda-deps.yml").write_text(good_config)
    environment = dict(os.environ, AGDA_DIR=str(registry))
    environment.pop("AGDA_DEPS_CONFIG", None)
    entry = "../project/src/Entry.agda"

    def run(args, *, env=None, succeeds=True):
        result = subprocess.run(
            [str(binary), *args], cwd=caller,
            env=environment | (env or {}), capture_output=True, text=True,
        )
        assert (result.returncode == 0) == succeeds, (
            args, result.returncode, result.stdout, result.stderr,
        )
        return result

    def graph(output, *, entry_module="Entry", unused=False):
        path = caller / output / "deps.json"
        assert path.exists(), f"missing JSON output at invocation-relative {path}"
        value = json.loads(path.read_text())
        assert value["entryModule"] == entry_module, value["entryModule"]
        assert "Entry" in value["modules"], value["modules"]
        if unused:
            assert extra / "Unused.agda" in {Path(p).resolve() for p in value["sourceFiles"]}, value["sourceFiles"]
        return value

    for skip in (False, True):
        mode = ["--skip-agda"] if skip else []
        prefix = "skip" if skip else "normal"
        # Early output validation must respect the resolved CLI/config quiet
        # flag even when --lazy produces an informational notice.
        quiet_config = caller / "quiet.yml"
        quiet_config.write_text(good_config + "quiet: true\n")
        for suffix, flags, quiet in (
            ("notice", [], False),
            ("cli", ["--quiet"], True),
            ("config", ["--config", str(quiet_config)], True),
        ):
            output = f"out/{prefix}-lazy-{suffix}"
            result = run([*mode, *flags, "--lazy", "--json-mode=expanded",
                          "-i../project/src", "-o" + output, entry])
            if quiet:
                assert result.stderr == "", (suffix, result.stderr)
            else:
                assert "--lazy only splits packed JSON" in result.stderr, result.stderr
            graph(output)
        # Named configs bind to the invocation directory before auto-discovery
        # changes cwd. A valid but different config at the new cwd is a trap.
        for suffix, flags, env in (
            ("config-pair", ["--config", "chosen.yml"], {}),
            ("config-equal", ["--config=chosen.yml"], {}),
            ("config-last", ["--config=missing.yml", "--config", "chosen.yml"], {}),
            ("config-env", [], {"AGDA_DEPS_CONFIG": "chosen.yml"}),
            ("config-cli-wins", ["--config=chosen.yml"], {"AGDA_DEPS_CONFIG": "missing.yml"}),
        ):
            output = f"out/{prefix}-{suffix}"
            result = run([*mode, *flags, "-i../project/src", "-o" + output, entry], env=env)
            assert "changing directory to project root " + str(project) in result.stderr
            graph(output)

        # Short attached paths, pairs and long forms have identical roots and
        # scanning inventories, including an unimported module under a second -i.
        for suffix, includes, output_flag in (
            ("attached", ["-i../project/src", "-i../project/extra"], lambda p: ["-o" + p]),
            ("pair", ["-i", "../project/src", "-i", "../project/extra"], lambda p: ["-o", p]),
            ("long", ["--include-path=../project/src", "--include-path", "../project/extra"],
             lambda p: ["--out-dir=" + p]),
        ):
            output = f"out/{prefix}-paths-{suffix}"
            run([*mode, *includes, *output_flag(output), entry])
            graph(output, unused=True)

        # Last CLI -o determines inference; explicit format wins in either order.
        for suffix, destinations, explicit, expected in (
            ("last-json", ["-o", "discarded.dot", "-o", "OUTPUT.json"], [], "json"),
            ("last-dot", ["-odiscarded.json", "--out-dir=OUTPUT.dot"], [], "dot"),
            ("last-dir", ["-odiscarded.json", "-oOUTPUT"], [], "dot"),
            ("attached-json", ["-oOUTPUT.json"], [], "json"),
            ("explicit-before", ["-oOUTPUT.json"], ["--format=dot"], "dot"),
            ("explicit-after", ["-oOUTPUT.dot", "--format=json"], [], "json"),
        ):
            output = f"out/{prefix}-format-{suffix}"
            destinations = [a.replace("OUTPUT", output) for a in destinations]
            final_output = output + (".json" if suffix in ("last-json", "attached-json", "explicit-before")
                                     else ".dot" if suffix in ("last-dot", "explicit-after") else "")
            run([*mode, "--no-libraries", "--json-mode=expanded", *explicit,
                 *destinations, "-i../project/src", entry])
            assert (caller / final_output / f"deps.{expected}").exists(), (suffix, expected)
            assert not (caller / "discarded.dot").exists()
            assert not (caller / "discarded.json").exists()
            if expected == "json":
                graph(final_output)

        # -o=DIR means a literal leading '=' in the value, as in GetOpt.
        output = f"={prefix}.json"
        run([*mode, "--no-libraries", "--json-mode=expanded", "-i../project/src",
             "-o" + output, entry])
        graph(output)

        # Explicit library selection opts out of root discovery in every spelling.
        for suffix, library_flag in (
            ("attached", ["-lfixture-library"]),
            ("pair", ["-l", "fixture-library"]),
            ("long", ["--library=fixture-library"]),
        ):
            output = f"out/{prefix}-library-{suffix}.json"
            result = run([*mode, *library_flag, "--json-mode=expanded",
                          "-i../project/src", "-o" + output, entry])
            assert "changing directory to project root" not in result.stderr
            assert "Entry" in graph(output)["externalModules"]

        # Backend operands must not trigger config/help/format preprocessing.
        for suffix, operand in (
            ("config", "--config=missing.yml"),
            ("help", "--help"),
            ("format", "--format=dot"),
            ("lenient", "--lenient-imports"),
            ("resolve", "--resolve-deps"),
            ("boundary", "--"),
        ):
            output = f"out/{prefix}-operand-{suffix}.json"
            run([*mode, "--no-libraries", "--json-mode=expanded", "--exclude", operand,
                 "-i../project/src", "-o" + output, entry])
            graph(output)
        for flag in ("--config", "--out-dir", "-i", "-l"):
            result = run([*mode, flag], succeeds=False)
            assert "requires an argument" in result.stderr and flag in result.stderr

    # Include-only skip scans must also discover the root with attached -i.
    output = "out/skip-include-only"
    run(["--skip-agda", "-i../project/src", "-o" + output])
    graph(output, entry_module=None)

    # Core Agda option operands must not be reparsed as backend flags/sources.
    output = "out/core-operand.json"
    run(["--no-libraries", "--json-mode=expanded", "--compile-dir", "--skip-agda",
         "-i../project/src", "-o" + output, entry])
    value = graph(output)
    assert value["definitions"], "Agda option's operand triggered skip mode"
    output = "out/core-source-operand.json"
    run(["--skip-agda", "--no-libraries", "--json-mode=expanded", "--compile-dir",
         "../project/extra/Unused.agda", "-o" + output, entry])
    value = graph(output)
    assert "Unused" not in value["modules"] and value["entryModule"] == "Entry"

    boundary = caller / "--config=trap"
    boundary.mkdir()
    (boundary / "Entry.agda").write_text((src / "Entry.agda").read_text())
    for mode in ([], ["--skip-agda"]):
        output = "out/boundary-" + ("skip" if mode else "normal") + ".json"
        run([*mode, "--no-libraries", "--json-mode=expanded", "-i" + str(boundary), "-o" + output,
             "--", "--config=trap/Entry.agda"])
        assert graph(output)["moduleFiles"]["Entry"] == str(boundary / "Entry.agda")

    # '--' protects even options which normally short-circuit or get stripped.
    for token in ("--help", "--version", "--emit-schema", "--show-defaults",
                  "--config=missing.yml", "--format=json"):
        result = run(["--no-libraries", "--", token], succeeds=False)
        assert "agda-deps: --config:" not in result.stderr
        assert not result.stdout.startswith(("agda-deps 1.", "Usage:", "{", "#"))
    # Unknown Agda flags survive forwarding and are diagnosed by Agda.
    result = run(["--no-libraries", "--unknown-argument-regression", entry], succeeds=False)
    assert "--unknown-argument-regression" in result.stdout + result.stderr

    for flags in (["--config", "--help"], ["--config=missing.yml", "--config=chosen.yml"]):
        result = run(["doctor", *flags])
        assert "origin" in result.stdout and "Usage:" not in result.stdout
    result = run(["doctor", "--config"], succeeds=False)
    assert result.returncode == 2 and "requires an argument" in result.stderr
    result = run(["doctor", "--", "--help"], succeeds=False)
    assert result.returncode == 2 and "unexpected argument" in result.stderr
    run(["doctor", "--"])

    help_text = run(["--help"]).stdout
    for flag in ("-h", "-?"):
        assert run([flag]).stdout == help_text
    # The enabled backend still requires an input file after upstream help;
    # compare forwarded forms without changing that existing exit behavior.
    assert run(["--help=warning"], succeeds=False).stdout == run(["-?warning"], succeeds=False).stdout
    assert run(["--agda-help"], succeeds=False).stdout != help_text
    assert run(["--version"]).stdout == run(["-V"]).stdout

    # The resolver now returns paths to the structured argv builder. Check
    # that its injected include paths still reach both Agda and the scan.
    (project / "project.agda-lib").write_text(
        "name: project\ninclude: src\ndepend: fixture-library\n"
    )
    (caller / "resolve.yml").write_text(good_config + "resolve-deps: true\n")
    for mode in ([], ["--skip-agda"]):
        for suffix, flags in (("cli", ["--resolve-deps"]),
                              ("config", ["--config=resolve.yml"])):
            output = f"out/resolve-{'skip' if mode else 'normal'}-{suffix}"
            result = run([*mode, *flags, "-i../project/src", "-o" + output, entry])
            assert "--resolve-deps: pinned" in result.stderr, result.stderr
            graph(output, unused=True)

    # Other path-valued flags must stay anchored across root discovery too.
    run(["--incremental", "--cache-dir=cache/invocation", "-i../project/src",
         "-oout/cache-path", entry])
    graph("out/cache-path")
    assert (caller / "cache/invocation").is_dir()
    assert not (project / "cache/invocation").exists()
    print("argv semantics OK (normal, skip, doctor; paths, inference, operands, boundary)")


def main():
    if len(sys.argv) != 2:
        print("usage: arguments_check.py /path/to/agda-deps", file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="agda-deps-arguments-") as tmp:
        check(binary, Path(tmp))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
