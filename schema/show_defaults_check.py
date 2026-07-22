#!/usr/bin/env python3
"""Drift guard for ``agda-deps --show-defaults``.

The sample ``.agda-deps.yml`` emitted by ``--show-defaults`` must document
exactly the config keys the backend actually reads. This compares the
commented keys in the emitted sample against the ``.:? "<key>"`` keys of the
``FromJSON Config`` instance in ``src/AgdaDeps/Config.hs`` — so a flag added
to the parser but not to the sample (or a typo/stale key in the sample) fails
CI rather than silently shipping a wrong sample.

Stdlib only (regex + text); no YAML dependency.

Usage::

    agda-deps --show-defaults > sample.yml
    python3 schema/show_defaults_check.py sample.yml src/AgdaDeps/Config.hs
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


def main(argv):
    if len(argv) != 3:
        print(
            "usage: show_defaults_check.py <sample.yml> <Config.hs>",
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

    missing = parsed - emitted  # read by the backend, absent from the sample
    extra = emitted - parsed    # in the sample, not read by the backend

    if missing:
        print(
            "keys read by FromJSON Config but missing from --show-defaults sample:",
            file=sys.stderr,
        )
        for k in sorted(missing):
            print("  - " + k, file=sys.stderr)
    if extra:
        print(
            "keys in --show-defaults sample not read by FromJSON Config (typo/stale?):",
            file=sys.stderr,
        )
        for k in sorted(extra):
            print("  - " + k, file=sys.stderr)

    if missing or extra:
        print(
            "\n--show-defaults sample has drifted from FromJSON Config; "
            "update Config.showDefaultsYaml.",
            file=sys.stderr,
        )
        return 1

    print("OK: --show-defaults documents all %d FromJSON Config keys." % len(parsed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
