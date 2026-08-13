#!/usr/bin/env python3
"""Drift guard for the config key set.

``FromJSON Config`` (``src/AgdaDeps/Config.hs``) is the source of truth: the
``.:? "<key>"`` keys it reads are the config keys the backend honours. Two
hand-maintained mirrors must list exactly the same set, and this fails CI when
either drifts:

* the commented sample ``.agda-deps.yml`` emitted by ``--show-defaults``
  (``Config.showDefaultsYaml``) — so a flag added to the parser but not to the
  sample, or a typo/stale key in the sample, is caught;
* the ``field "<key>" …`` table in ``src/AgdaDeps/Doctor.hs`` (optional third
  argument) — a key missing there would make ``agda-deps doctor`` report a
  perfectly good key as unknown.

Stdlib only (regex + text); no YAML dependency.

Usage::

    agda-deps --show-defaults > sample.yml
    python3 schema/show_defaults_check.py sample.yml src/AgdaDeps/Config.hs \\
        [src/AgdaDeps/Doctor.hs]
"""
import re
import sys


def emitted_keys(sample_text):
    # Sample key lines are "#<key>: ..." — '#' immediately followed by a
    # kebab-case key. Section headers ("# ---") and prose ("# text") start
    # with "# " (hash-space) and are skipped.
    return {m.group(1) for m in re.finditer(r"(?m)^#([a-z][a-z-]*):", sample_text)}


def fromjson_keys(config_src):
    # Every config field is parsed as  o .:? "<kebab-key>".
    return set(re.findall(r'\.:\?\s*"([a-z-]+)"', config_src))


def doctor_keys(doctor_src):
    # Every checked key is declared as  field "<kebab-key>" <type>.
    return {m.group(1) for m in re.finditer(r'field\s+"([a-z-]+)"', doctor_src)}


def compare(parsed, mirror, what, fix):
    """Report both directions of drift; return True when they agree."""
    missing = parsed - mirror  # read by the backend, absent from the mirror
    extra = mirror - parsed    # in the mirror, not read by the backend

    if missing:
        print("keys read by FromJSON Config but missing from %s:" % what, file=sys.stderr)
        for k in sorted(missing):
            print("  - " + k, file=sys.stderr)
    if extra:
        print("keys in %s not read by FromJSON Config (typo/stale?):" % what, file=sys.stderr)
        for k in sorted(extra):
            print("  - " + k, file=sys.stderr)

    if missing or extra:
        print("\n%s has drifted from FromJSON Config; %s." % (what, fix), file=sys.stderr)
        return False
    return True


def main(argv):
    if len(argv) not in (3, 4):
        print(
            "usage: show_defaults_check.py <sample.yml> <Config.hs> [Doctor.hs]",
            file=sys.stderr,
        )
        return 2

    with open(argv[1], encoding="utf-8") as f:
        emitted = emitted_keys(f.read())
    with open(argv[2], encoding="utf-8") as f:
        parsed = fromjson_keys(f.read())

    if not parsed:
        print("no FromJSON keys found in " + argv[2] + " (regex broken?)", file=sys.stderr)
        return 2

    ok = compare(
        parsed,
        emitted,
        "the --show-defaults sample",
        "update Config.showDefaultsYaml",
    )

    if len(argv) == 4:
        with open(argv[3], encoding="utf-8") as f:
            doctored = doctor_keys(f.read())
        if not doctored:
            print("no `field \"...\"` keys found in " + argv[3] + " (regex broken?)", file=sys.stderr)
            return 2
        ok = compare(
            parsed,
            doctored,
            "the agda-deps doctor key table",
            "update Doctor.knownFields",
        ) and ok

    if not ok:
        return 1

    print("OK: every mirror documents all %d FromJSON Config keys." % len(parsed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
