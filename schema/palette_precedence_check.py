#!/usr/bin/env python3
"""Check CLI theme/colour precedence in emitted DOT and incremental output.

Usage: python3 schema/palette_precedence_check.py /path/to/agda-deps
Uses temporary projects and an isolated Agda library registry.
"""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


KEYS = ("color-defined", "color-postulate", "color-hole", "color-failed")
THEMES = {
    "default": ("#4caf50", "#f44336", "#9c27b0", "#ff9800"),
    "light": ("#4caf50", "#f44336", "#9c27b0", "#ff9800"),
    "dark": ("#81c784", "#ef5350", "#ba68c8", "#ffb74d"),
    "colorblind": ("#1b9e77", "#d95f02", "#7570b3", "#e7298a"),
}
CHOSEN = ("#112233", "#445566", "#778899", "#aAbBcC")


def replace(palette, index, colour):
    values = list(palette)
    values[index] = colour
    return tuple(values)


def dot_colours(dot):
    colours = {}
    for block in re.findall(r"\[([^\]]*fillcolor[^\]]*)\]", dot, re.S):
        label = re.search(r'\blabel\s*=\s*(?:"([^"\n]+)"|([\w.]+))', block)
        colour = re.search(r'\bfillcolor\s*=\s*"(#[\da-fA-F]{6})"', block)
        assert label and colour, block
        colours[label.group(1) or label.group(2)] = colour.group(1).lower()
    return colours


def check(binary, root):
    src = root / "src"
    src.mkdir()
    (src / "Good.agda").write_text(
        "module Good where\ndata Unit : Set where\n  unit : Unit\n"
        "postulate p : Unit\nhole : Unit\nhole = ?\n",
    )
    (src / "Broken.agda").write_text("module Broken where\nbroken : Set\nbroken = Set\n")
    (src / "Entry.agda").write_text("module Entry where\nimport Good\nimport Broken\n")
    (src / "Cache.agda").write_text(
        "module Cache where\ndata Unit : Set where\n  unit : Unit\npostulate p : Unit\n",
    )
    registry = root / "registry"
    registry.mkdir()
    environment = dict(os.environ, AGDA_DIR=str(registry))
    environment.pop("AGDA_DEPS_CONFIG", None)
    config = root / "chosen.yml"
    counter = 0

    def invoke(flags, *, yaml="{}\n", keep=False, skip=False, succeeds=True,
               output=None, cache=None, entry=None, fmt="dot"):
        nonlocal counter
        counter += 1
        config.write_text(yaml)
        output = output or root / f"output-{counter}"
        args = ["--config", config, "--no-libraries", "--no-externals",
                f"--format={fmt}", "--json-mode=expanded", "-i", src, "-o", output]
        if keep:
            args.append("--keep-going")
        if skip:
            args.append("--skip-agda")
        if cache is not None:
            args.extend(["--incremental", "--cache-dir", cache])
        else:
            args.append("--allow-unsolved-metas")
        entry = entry or ("Entry" if keep else "Good")
        result = subprocess.run(
            [str(binary), *map(str, args), *flags, str(src / (entry + ".agda"))],
            cwd=root, env=environment, capture_output=True, text=True,
        )
        assert (result.returncode == 0) == succeeds, (
            flags, yaml, result.returncode, result.stdout, result.stderr,
        )
        if not succeeds:
            assert not output.exists(), output
            assert "pre-compute:" not in result.stderr, result.stderr
            return result, None
        return result, (output / f"deps.{fmt}").read_text()

    def expect(flags, palette, *, yaml="{}\n", keep=False):
        _, dot = invoke(flags, yaml=yaml, keep=keep)
        colours = dot_colours(dot)
        labels = ("Unit", "p", "hole", "Broken") if keep else ("Unit", "p", "hole")
        for index, label in enumerate(labels):
            assert colours.get(label) == palette[index].lower(), (
                flags, yaml, label, palette[index], colours, dot,
            )
        return dot

    # Reproduces the original bug: a later theme erased the explicit colour.
    before = ["--color-defined=#123456", "--theme=dark"]
    after = ["--theme=dark", "--color-defined=#123456"]
    expected = replace(THEMES["dark"], 0, "#123456")
    assert expect(before, expected) == expect(after, expected)

    # Render all four states, including the failed-module marker, to prove
    # each palette slot works through Agda's normal and keep-going parsers.
    overrides = [f"--{key}={value}" for key, value in zip(KEYS, CHOSEN)]
    expect([*overrides, "--theme=dark"], CHOSEN, keep=True)
    expect(["--theme=dark", *overrides], CHOSEN, keep=True)
    expect(["--color-failed", CHOSEN[3], "--theme", "dark", "--color-defined", CHOSEN[0],
            "--theme=light", "--color-hole", CHOSEN[2], "--color-postulate", CHOSEN[1],
            "--theme=colorblind"], CHOSEN, keep=True)
    for name, palette in THEMES.items():
        expect([f"--theme={name}"], palette, keep=True)
    expect(["--theme=dark", "--color-hole=#123456", "--theme=light", "--theme=colorblind"],
           replace(THEMES["colorblind"], 2, "#123456"), keep=True)
    expect(["--color-defined=#123456", "--theme=dark", "--color-defined=#aBcDeF",
            "--theme=colorblind"], replace(THEMES["colorblind"], 0, "#abcdef"), keep=True)

    # Defaults -> YAML -> CLI: YAML colours are not CLI overrides. A CLI
    # theme resets them; explicit CLI colours then override that theme.
    yaml = "theme: dark\n" + "".join(
        f'{key}: "{value}"\n' for key, value in zip(KEYS, CHOSEN)
    )
    expect([], CHOSEN, yaml=yaml, keep=True)
    expect(["--color-defined=#abcdef"], replace(CHOSEN, 0, "#abcdef"), yaml=yaml, keep=True)
    expect(["--theme=colorblind"], THEMES["colorblind"], yaml=yaml, keep=True)
    for flags in (["--color-failed=#abcdef", "--theme=colorblind"],
                  ["--theme=colorblind", "--color-failed=#abcdef"]):
        expect(flags, replace(THEMES["colorblind"], 3, "#abcdef"), yaml=yaml, keep=True)
    expect(["--color-hole=#abcdef"], replace(THEMES["dark"], 2, "#abcdef"), yaml="theme: dark\n")

    # Option operands that resemble palette flags remain values.
    expect(["--exclude=--color-defined=#000000", "--theme=dark"], THEMES["dark"])
    expect(["--compile-dir", "--theme=colorblind", *before], expected)

    # Skip mode consumes the same shared actions and retains module DOT.
    for skip in (False, True):
        for flags, diagnostic in (
            (["--theme=invalid", "--theme=dark"], "Unknown theme value"),
            (["--color-defined=invalid", "--theme=dark", "--color-defined=#abcdef"],
             "Invalid value for --color-defined"),
        ):
            result, _ = invoke(flags, skip=skip, succeeds=False)
            assert diagnostic in result.stderr, result.stderr
    _, skip_before = invoke(before, yaml=yaml, skip=True)
    _, skip_after = invoke(after, yaml=yaml, skip=True)
    assert skip_before == skip_after

    # DOT always emits, but must reuse extracted fragments and honour new
    # colours. JSON serialization can skip when the final palette is equal;
    # parser bookkeeping must not make equivalent flag orders look different.
    output = root / "incremental-output"
    cache = root / "cache"

    def incremental(flags):
        return invoke(flags, output=output, cache=cache, entry="Cache")

    _, initial = incremental(["--theme=dark"])
    assert dot_colours(initial)["Unit"] == THEMES["dark"][0]
    result, changed = incremental(before)
    assert dot_colours(changed)["Unit"] == "#123456", changed
    assert "skipped re-emit" not in result.stderr, result.stderr
    assert "fragment hit" in result.stderr, result.stderr
    result, unchanged = incremental(after)
    assert changed == unchanged and "fragment hit" in result.stderr, result.stderr
    result, changed_again = incremental(["--color-defined=#abcdef", "--theme=dark"])
    assert dot_colours(changed_again)["Unit"] == "#abcdef", changed_again
    assert "skipped re-emit" not in result.stderr and "fragment hit" in result.stderr

    json_output = root / "incremental-json"

    def incremental_json(flags):
        return invoke(flags, output=json_output, cache=cache, entry="Cache", fmt="json")

    incremental_json(["--theme=dark"])
    result, changed = incremental_json(before)
    assert "skipped re-emit" not in result.stderr and "fragment hit" in result.stderr
    result, unchanged = incremental_json(after)
    assert changed == unchanged and "skipped re-emit" in result.stderr, result.stderr
    _, changed = incremental_json([*overrides, "--theme=dark"])
    result, unchanged = incremental_json(["--theme=dark", *reversed(overrides)])
    assert changed == unchanged and "skipped re-emit" in result.stderr, result.stderr

    print("palette precedence OK (all four states, repeated flags, YAML layers, normal/skip/keep-going, incremental reuse)")


def main():
    if len(sys.argv) != 2:
        print("usage: palette_precedence_check.py /path/to/agda-deps", file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="agda-deps-palette-") as tmp:
        check(binary, Path(tmp))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
