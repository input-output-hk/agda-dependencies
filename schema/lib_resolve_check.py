#!/usr/bin/env python3
"""Check version-aware, all-or-nothing --resolve-deps in normal and skip modes.

Usage: python3 schema/lib_resolve_check.py /path/to/agda-deps
Each case has an isolated project and Agda library registry.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


class Fixture:
    def __init__(self, binary, root, label, dependencies):
        self.binary = binary
        self.root = root / label
        self.project = self.root / "project"
        self.src = self.project / "src"
        self.registry_dir = self.root / "registry"
        self.src.mkdir(parents=True)
        self.registry_dir.mkdir()
        self.project_file = self.project / "project.agda-lib"
        self.project_file.write_text(
            "name: project\ninclude: src\ndepend: " + dependencies + "\n"
        )
        self.entry = self.src / "Entry.agda"
        self.entry.write_text("module Entry where\ndata Unit : Set where\n  unit : Unit\n")
        self.registry = self.registry_dir / "libraries"
        self.libraries = []
        self.env = dict(os.environ, AGDA_DIR=str(self.registry_dir))
        self.env.pop("AGDA_DEPS_CONFIG", None)

    def library(self, label, name, module="Shared", dependencies="", include="src"):
        directory = self.project / "libraries" / label
        sources = directory / include
        sources.mkdir(parents=True)
        path = directory / "library.agda-lib"
        include_field = include.replace(" ", "\\ ")
        path.write_text(
            f"name: {name}\ninclude: {include_field}\ndepend: {dependencies}\n"
        )
        source = sources / (module + ".agda")
        source.write_text(f"module {module} where\npostulate token : Set\n")
        self.libraries.append(path)
        return path, source

    def register(self, paths=None):
        self.registry.write_text("\n".join(map(str, self.libraries if paths is None else paths)) + "\n")

    def imports(self, modules):
        self.entry.write_text(self.entry.read_text() +
                              "".join(f"import {module}\n" for module in modules))

    def run(self, skip, extra=(), succeeds=True, suffix=""):
        output = self.root / ("skip" if skip else "normal") / suffix
        flags = ["--skip-agda"] if skip else []
        result = subprocess.run(
            [str(self.binary), "--resolve-deps", *flags, "--format=json",
             "--json-mode=expanded", "-o", str(output), *map(str, extra), str(self.entry)],
            cwd=self.project, env=self.env, capture_output=True, text=True,
            timeout=30,
        )
        assert (result.returncode == 0) == succeeds, (
            self.root.name, skip, result.returncode, result.stdout, result.stderr,
        )
        graph = json.loads((output / "deps.json").read_text()) if succeeds else None
        return result, graph

    def success(self, expected, extra=()):
        for skip in (False, True):
            result, graph = self.run(skip, extra)
            assert "--resolve-deps: pinned" in result.stderr, result.stderr
            assert "resolution failed" not in result.stderr, result.stderr
            files = {Path(p).resolve() for p in graph["sourceFiles"]}
            assert files == {self.entry, *expected.values()}, (self.root.name, skip, files)
            assert graph["entryModule"] == "Entry", graph["entryModule"]
            for module, path in expected.items():
                assert Path(graph["moduleFiles"][module]).resolve() == path, graph["moduleFiles"]

    def failure(self, diagnostic, extra=(), manual_sources=()):
        for skip in (False, True):
            result, graph = self.run(skip, extra, succeeds=skip)
            assert "--resolve-deps: resolution failed:" in result.stderr, result.stderr
            assert "leaving argv unchanged" in result.stderr, result.stderr
            assert "--resolve-deps: pinned" not in result.stderr, result.stderr
            assert diagnostic in result.stderr, (diagnostic, result.stderr)
            if skip:
                # A fallback must not expose even successfully resolved siblings.
                files = {Path(p).resolve() for p in graph["sourceFiles"]}
                assert files == {self.entry, *manual_sources}, (self.root.name, files)


def check(binary, root):
    # Unversioned requests choose the highest numeric version when no bare
    # name exists. An exact bare name takes precedence; a pinned version wins
    # over newer installed versions, including equivalent leading-zero forms.
    for label, request, bare, chosen in (
        ("latest", "shared-library", False, "new"),
        ("bare", "shared-library", True, "bare"),
        ("exact", "shared-library-2.9", False, "old"),
        ("numeric", "shared-library-02.09", False, "old"),
    ):
        fixture = Fixture(binary, root, label, request)
        _, old = fixture.library("old", "shared-library-2.9")
        _, new = fixture.library("new", "shared-library-2.10")
        selected = {"old": old, "new": new}
        if bare:
            _, selected["bare"] = fixture.library("bare", "shared-library")
        fixture.register()
        fixture.imports(["Shared"])
        fixture.success({"Shared": selected[chosen]})

    # Reproduce the prettyprint -> unversioned standard-library dependency
    # pattern, and check multiline fields, comments and escaped include paths.
    fixture = Fixture(binary, root, "transitive", "prettyprint-1.0")
    pretty, pretty_source = fixture.library("prettyprint", "prettyprint-1.0", "Pretty",
                                            "standard-library", include="source files")
    pretty.write_text('name: prettyprint-1.0\ninclude: source\\ files -- comment\n'
                      'depend:\n  standard-library -- comment\n')
    _, standard = fixture.library("stdlib", "standard-library-2.10", "Standard")
    fixture.register()
    fixture.imports(["Pretty", "Standard"])
    fixture.success({"Pretty": pretty_source, "Standard": standard})

    fixture = Fixture(binary, root, "cycles", "cycle-a, cycle-a")
    a, a_source = fixture.library("a", "cycle-a", "CycleA", "cycle-b")
    b, b_source = fixture.library("b", "cycle-b", "CycleB", "cycle-a")
    fixture.register([a, b, a])  # Repeating one file is not an ambiguity.
    fixture.imports(["CycleA", "CycleB"])
    fixture.success({"CycleA": a_source, "CycleB": b_source})

    # One unresolved transitive request discards the entire pin, even when
    # siblings have already resolved. Explicit user include paths survive.
    fixture = Fixture(binary, root, "partial", "good broken")
    fixture.library("good", "good", "Good")
    fixture.library("broken", "broken", "Broken", "missing-transitive")
    fixture.register()
    manual = fixture.project / "manual"
    manual.mkdir()
    manual_source = manual / "Manual.agda"
    manual_source.write_text("module Manual where\n")
    fixture.failure("missing-transitive", extra=["-i", manual], manual_sources=[manual_source])

    fixture = Fixture(binary, root, "missing-version", "shared-library-3")
    fixture.library("only", "shared-library-2.10")
    fixture.register()
    fixture.failure("shared-library-3")

    # Preserve distinct entries instead of Map.fromList silently choosing one.
    for label, names in (("ambiguous", ("shared-library-1.0", "shared-library-1.0")),
                         ("ambiguous-numeric", ("shared-library-01.0", "shared-library-1.0"))):
        fixture = Fixture(binary, root, label, "shared-library")
        fixture.library("first", names[0])
        fixture.library("second", names[1])
        fixture.register()
        fixture.failure("Ambiguous")

    fixture = Fixture(binary, root, "malformed-library", "good bad")
    fixture.library("good", "good", "Good")
    bad, _ = fixture.library("bad", "bad", "Bad")
    bad.write_text("name: bad\nname: duplicate\ninclude: src\n")
    fixture.register()
    fixture.failure(str(bad))

    fixture = Fixture(binary, root, "missing-registry-entry", "good")
    good, _ = fixture.library("good", "good", "Good")
    missing = fixture.project / "missing.agda-lib"
    fixture.register([good, missing])
    fixture.failure(str(missing))

    fixture = Fixture(binary, root, "malformed-project", "good")
    fixture.library("good", "good", "Good")
    fixture.register()
    fixture.project_file.write_text("name: project\ninclude: src\ninclude: duplicate\ndepend: good\n")
    fixture.failure("Duplicate")

    fixture = Fixture(binary, root, "missing-registry", "missing-library")
    fixture.failure("missing-library")

    # Agda gives its version-specific registry priority over 'libraries'.
    fixture = Fixture(binary, root, "versioned-registry", "shared-library")
    default, _ = fixture.library("default", "shared-library")
    versioned, selected = fixture.library("versioned", "shared-library")
    fixture.register([default])
    for version in ("2.8.0", "2.9.0"):
        (fixture.registry_dir / ("libraries-" + version)).write_text(str(versioned) + "\n")
    fixture.imports(["Shared"])
    fixture.success({"Shared": selected})

    # The CLI registry override must also govern the pre-Agda resolver.
    fixture = Fixture(binary, root, "registry-override", "shared-library")
    default, _ = fixture.library("default", "shared-library")
    override, selected = fixture.library("override", "shared-library")
    fixture.register([default])
    alternate = fixture.project / "alternate-libraries"
    alternate.write_text(str(override) + "\n")
    fixture.imports(["Shared"])
    fixture.success({"Shared": selected}, extra=["--library-file", alternate])

    # A registry change must select the new version and invalidate serialized
    # output, even when the two libraries have byte-identical source contents.
    fixture = Fixture(binary, root, "incremental-version", "shared-library")
    old, old_source = fixture.library("old", "shared-library-1")
    new, new_source = fixture.library("new", "shared-library-2")
    fixture.imports(["Shared"])
    fixture.register([old])
    incremental = ["--incremental"]
    _, before = fixture.run(False, incremental)
    assert Path(before["moduleFiles"]["Shared"]).resolve() == old_source
    result, _ = fixture.run(False, incremental)
    assert "skipped re-emit" in result.stderr, result.stderr
    fixture.register([old, new])
    result, after = fixture.run(False, incremental)
    assert "skipped re-emit" not in result.stderr, result.stderr
    assert Path(after["moduleFiles"]["Shared"]).resolve() == new_source, after["moduleFiles"]
    assert new_source in {Path(p).resolve() for p in after["sourceFiles"]}
    assert old_source not in {Path(p).resolve() for p in after["sourceFiles"]}
    result, repeated = fixture.run(False, incremental)
    assert "fragment hit for 'Shared'" in result.stderr, result.stderr
    assert Path(repeated["moduleFiles"]["Shared"]).resolve() == new_source
    # After a context change, a warm main interface cannot seed its new
    # fragment (dead-private recovery needs a cold main). Preserve that
    # existing policy and verify the new context's steady-state no-op too.
    interfaces = list(fixture.project.rglob("Entry.agdai"))
    assert interfaces, "expected a main-module interface to clear"
    for path in interfaces:
        path.unlink()
    fixture.run(False, incremental)
    result, _ = fixture.run(False, incremental)
    assert "skipped re-emit" in result.stderr, result.stderr

    fixture = Fixture(binary, root, "missing-override", "good")
    fixture.library("good", "good", "Good")
    fixture.register()
    missing = fixture.project / "missing-libraries"
    fixture.failure(str(missing), extra=["--library-file", missing])

    # No dependencies and no project are deliberate no-op cases.
    for label, remove_project in (("no-dependencies", False), ("no-project", True)):
        fixture = Fixture(binary, root, label, "")
        if remove_project:
            fixture.project_file.unlink()
        for skip in (False, True):
            result, graph = fixture.run(skip, extra=["-i", fixture.src])
            assert "leaving argv unchanged" in result.stderr, result.stderr
            assert "--resolve-deps: pinned" not in result.stderr, result.stderr
            assert graph["entryModule"] == "Entry"

    print("library resolution OK (normal/skip; versions, atomic fallback, ambiguity, parsing, cycles, registries)")


def main():
    if len(sys.argv) != 2:
        print("usage: lib_resolve_check.py /path/to/agda-deps", file=sys.stderr)
        return 2
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="agda-deps-libraries-") as tmp:
        check(binary, Path(tmp))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
