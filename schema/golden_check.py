#!/usr/bin/env python3
"""Golden-snapshot guard for expanded ``graph.json``.

Phase-2 makes the emitted *shape* match the schema by construction, and
``check_schema.py`` guards the schema itself. This script guards the
emitted *content* (node states, kinds, edges, provenance, reexports,
subterm hashes, …) against silent semantic regressions a schema can't
catch — e.g. an edge dropped, a state flipped, a kind miscomputed.

It normalises away the few fields that legitimately vary by build /
environment so the golden is portable across machines and CI:

  * ``producer``         — build fingerprint (git rev / date / GHC).
  * per-definition ``x`` / ``y`` — layout positions (sfdp is
    Graphviz-version dependent; the threshold grid is deterministic but
    we normalise unconditionally to stay robust).
  * ``moduleFiles`` values and ``sourceFiles`` — absolute file paths
    (machine dependent) → basenames, sorted.

Everything else (incl. node ``id`` / ordering and subterm hashes, which
derive from Agda's deterministic Murmur ``hashString``) is compared
verbatim.

Usage:
    golden_check.py emit  <deps.json>            # print normalised JSON (to (re)create the golden)
    golden_check.py check <deps.json> <golden>   # compare; exit 1 + diff on mismatch
"""
import json
import os
import sys


def normalize(g):
    g = dict(g)
    if "producer" in g:
        g["producer"] = "<normalised>"
    if isinstance(g.get("definitions"), list):
        g["definitions"] = [
            {k: v for k, v in d.items() if k not in ("x", "y")}
            for d in g["definitions"]
        ]
    if isinstance(g.get("moduleFiles"), dict):
        g["moduleFiles"] = {
            k: os.path.basename(v) for k, v in sorted(g["moduleFiles"].items())
        }
    if isinstance(g.get("sourceFiles"), list):
        g["sourceFiles"] = sorted(os.path.basename(p) for p in g["sourceFiles"])
    return g


def load(path):
    with open(path) as f:
        return json.load(f)


def main(argv):
    if len(argv) < 3 or argv[1] not in ("emit", "check"):
        sys.stderr.write(__doc__)
        return 2
    mode = argv[1]
    try:
        fresh = normalize(load(argv[2]))
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"error reading {argv[2]}: {e}\n")
        return 2

    if mode == "emit":
        print(json.dumps(fresh, indent=2, sort_keys=True))
        return 0

    # mode == "check"
    if len(argv) != 4:
        sys.stderr.write("usage: golden_check.py check <deps.json> <golden>\n")
        return 2
    try:
        golden = normalize(load(argv[3]))  # idempotent; tolerate raw or normalised golden
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"error reading golden {argv[3]}: {e}\n")
        return 2

    if fresh == golden:
        print("OK: expanded output matches the golden snapshot (normalised).")
        return 0

    import difflib
    a = json.dumps(golden, indent=2, sort_keys=True).splitlines()
    b = json.dumps(fresh, indent=2, sort_keys=True).splitlines()
    sys.stderr.write(
        "MISMATCH: expanded graph.json content changed vs the golden snapshot.\n"
        "If intended, regenerate: golden_check.py emit <deps.json> > "
        f"{argv[3]}\nNormalised diff (golden -> fresh):\n\n")
    for line in difflib.unified_diff(a, b, "golden", "fresh", lineterm=""):
        sys.stderr.write(line + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
