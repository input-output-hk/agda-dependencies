#!/usr/bin/env python3
"""Check YAML scalar validation before Agda, scanning, caching, or output.

Usage: python3 schema/config_validation_check.py /path/to/agda-deps
Uses temporary projects and an isolated Agda library registry.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


COLORS = ("color-defined", "color-postulate", "color-hole", "color-failed")


def snapshot(directory):
    return {
        str(path.relative_to(directory)): (
            path.stat().st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest(),
        )
        for path in directory.rglob("*") if path.is_file()
    }


def check(binary, root):
    src = root / "src"
    src.mkdir()
    entry = src / "Entry.agda"
    entry.write_text(
        "module Entry where\n"
        "data Unit : Set where\n  unit : Unit\n"
        "postulate p : Unit\n"
        "identity : Unit → Unit\nidentity x = x\n"
        "result : Unit\nresult = identity (identity unit)\n",
        encoding="utf-8",
    )
    registry = root / "registry"
    registry.mkdir()
    environment = dict(os.environ, AGDA_DIR=str(registry))
    environment.pop("AGDA_DEPS_CONFIG", None)
    config = root / "chosen.yml"
    counter = 0

    def run(args, *, succeeds=True):
        result = subprocess.run(
            [str(binary), *map(str, args)], cwd=root, env=environment,
            capture_output=True, text=True,
        )
        assert (result.returncode == 0) == succeeds, (
            args, result.returncode, result.stdout, result.stderr,
        )
        return result

    def invoke(text, *, skip=False, extra=(), succeeds=True, output=None, cache=None):
        nonlocal counter
        counter += 1
        config.write_text(text, encoding="utf-8")
        output = output or root / f"out-{counter}"
        args = ["--config", config, "--no-libraries", "-i", src, "-o", output]
        if skip:
            args.append("--skip-agda")
        if cache is not None:
            args.extend(["--incremental", "--cache-dir", cache])
        result = run([*args, *extra, entry], succeeds=succeeds)
        return result, output

    # Colours must be valid even in JSON output. Depth must be valid even
    # without hashes. Neither a valid CLI override nor skip mode bypasses
    # config validation. No Agda interfaces or cache/output may be created.
    invalid = [
        (key, value, "#RRGGBB")
        for key in COLORS
        for value in ('"black"', '"#12345"', '"#1234567"', '"#12gg56"',
                      '""', "42", "true", "[]", "null", "#123456")
    ] + [
        ("min-term-depth", value, "positive integer")
        for value in ("0", "-1", "-100", "1.5", '"1"', "true", "[]", "null",
                      "9223372036854775808")
    ]
    for skip in (False, True):
        for key, value, expected in invalid:
            cache = root / f"cache-{counter + 1}"
            override = "#abcdef" if key in COLORS else "1"
            result, output = invoke(
                f"format: json\n{key}: {value}\n", skip=skip,
                extra=[f"--{key}={override}"], succeeds=False, cache=cache,
            )
            assert str(config) in result.stderr, result.stderr
            assert key in result.stderr and expected in result.stderr, result.stderr
            assert "failed to parse config file" in result.stderr, result.stderr
            assert "Checking" not in result.stdout, result.stdout
            assert "pre-compute:" not in result.stderr, result.stderr
            assert not output.exists() and not cache.exists(), (output, cache)
            assert not list(src.rglob("*.agdai")) and not (src / "_build").exists()

    # Doctor still aggregates failures rather than stopping at the first key.
    for key, value, _ in invalid:
        config.write_text(f"{key}: {value}\n")
        result = run(["doctor", "--config", config], succeeds=False)
        assert key in result.stdout + result.stderr, result
    config.write_text('color-defined: "#bad"\nmin-term-depth: 0\n')
    result = run(["doctor", "--config", config], succeeds=False)
    assert all(key in result.stdout + result.stderr
               for key in ("color-defined", "min-term-depth")), result

    # Omitted keys, empty documents, and a freshly seeded sample retain the
    # defaults. Every uncommented sample field must also load successfully.
    sample = run(["--show-defaults"]).stdout
    uncommented = re.sub(r"(?m)^#([a-z][a-z-]*):", r"\1:", sample)
    for text in ("", "# empty config\n", "{}\n", "null\n", sample, uncommented):
        for skip in (False, True):
            _, output = invoke(text, skip=skip, extra=["--format=json", "--json-mode=expanded"])
            graph = json.loads((output / "deps.json").read_text())
            assert graph["entryModule"] == "Entry"
            assert bool(graph["definitions"]) != skip
        run(["doctor", "--config", config])

    # Mixed-case hex digits and the depth boundary work through both surfaces.
    # DOT must receive the actual palette, and CLI can override valid YAML.
    palette = dict(zip(COLORS, ("#aBcDeF", "#13579B", "#2468aC", "#FeDcBa")))
    color_config = "".join(f'{key}: "{value}"\n' for key, value in palette.items())
    _, yaml_output = invoke(color_config, extra=["--format=dot"])
    yaml_dot = (yaml_output / "deps.dot").read_text()
    _, cli_output = invoke("{}\n", extra=["--format=dot", *[
        f"--{key}={value}" for key, value in palette.items()
    ]])
    assert yaml_dot == (cli_output / "deps.dot").read_text()
    assert "#abcdef" in yaml_dot.lower() and "#13579b" in yaml_dot.lower(), yaml_dot
    _, override_output = invoke(color_config, extra=["--color-defined=#102030"])
    override_dot = (override_output / "deps.dot").read_text().lower()
    assert "#102030" in override_dot and "#abcdef" not in override_dot
    config.write_text(color_config)
    run(["doctor", "--config", config])

    depths_by_minimum = {}
    hash_flags = ["--format=json", "--json-mode=expanded", "--with-term-hashes"]
    for depth in (1, 2, 1000):
        for skip in (False, True):
            _, yaml_output = invoke(f"min-term-depth: {depth}\n", skip=skip, extra=hash_flags)
            _, cli_output = invoke("{}\n", skip=skip, extra=[*hash_flags, f"--min-term-depth={depth}"])
            yaml_graph = json.loads((yaml_output / "deps.json").read_text())
            cli_graph = json.loads((cli_output / "deps.json").read_text())
            for key in ("definitionSubtermHashes", "definitionSubtermDepths"):
                assert yaml_graph.get(key) == cli_graph.get(key), (depth, skip, key)
            if not skip:
                depths = yaml_graph["definitionSubtermDepths"]
                assert all(d >= depth for values in depths for d in values), depths
                depths_by_minimum[depth] = sum(map(len, depths))
        config.write_text(f"with-term-hashes: true\nmin-term-depth: {depth}\n")
        run(["doctor", "--config", config])
    assert depths_by_minimum[1] > depths_by_minimum[2] > depths_by_minimum[1000] == 0
    _, output = invoke("min-term-depth: 1000\n", extra=[*hash_flags, "--min-term-depth=1"])
    graph = json.loads((output / "deps.json").read_text())
    assert sum(map(len, graph["definitionSubtermDepths"])) == depths_by_minimum[1]

    # A previously successful incremental run must not skip validation or
    # touch any interfaces, fragments, or serialized output on failure.
    cache = root / "warm-cache"
    output = root / "warm-output"
    invoke("{}\n", extra=hash_flags, cache=cache, output=output)
    assert cache.exists() and list(src.rglob("*.agdai"))
    before = [snapshot(p) for p in (src, cache, output)]
    for skip in (False, True):
        for bad in ('color-failed: "oops"\n', "min-term-depth: 0\n"):
            invoke(bad, skip=skip, extra=hash_flags, succeeds=False, cache=cache, output=output)
            assert before == [snapshot(p) for p in (src, cache, output)]

    print("config validation OK (normal/skip; scalar domains, diagnostics, defaults, CLI parity, warm caches)")


def main():
    if len(sys.argv) != 2:
        print("usage: config_validation_check.py /path/to/agda-deps", file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="agda-deps-config-") as tmp:
        check(binary, Path(tmp))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
