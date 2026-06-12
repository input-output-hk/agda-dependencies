#!/usr/bin/env python3
"""Structural equality check between two JSON Schemas.

Used by CI to verify that the schema generated from the Haskell single
source of truth (``agda-deps --emit-schema``) still matches the committed
oracle ``schema/graph-v2-expanded.schema.json``. The committed file is
never overwritten — it is the frozen contract; a mismatch means the wire
shape changed in Haskell and the committed schema must be updated
deliberately (a reviewed change), which is exactly the silent-drift guard
we want.

Comparison is *structural*: documentation-only / identity keys
(``description``, ``$id``, ``$schema``, ``title``, ``$comment``) are
dropped, and order-insignificant arrays (``required``, ``enum``) are
sorted, before comparing. Object key order is irrelevant (dict equality).

Usage:
    check_schema.py <generated.json> <committed.json>
Exits 0 on match, 1 on mismatch (printing a unified diff of the
normalised forms), 2 on usage / parse error.
"""
import json
import sys

STRIP_KEYS = {"description", "$id", "$schema", "title", "$comment"}
SORT_ARRAYS = {"required", "enum"}


def normalize(x):
    if isinstance(x, dict):
        out = {}
        for k, v in x.items():
            if k in STRIP_KEYS:
                continue
            if k in SORT_ARRAYS and isinstance(v, list):
                out[k] = sorted(v)
            else:
                out[k] = normalize(v)
        return out
    if isinstance(x, list):
        return [normalize(e) for e in x]
    return x


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(f"usage: {argv[0]} <generated.json> <committed.json>\n")
        return 2
    generated_path, committed_path = argv[1], argv[2]
    try:
        with open(generated_path) as f:
            generated = normalize(json.load(f))
        with open(committed_path) as f:
            committed = normalize(json.load(f))
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"error reading schemas: {e}\n")
        return 2

    if generated == committed:
        print("OK: generated schema structurally matches the committed schema.")
        return 0

    import difflib
    a = json.dumps(committed, indent=2, sort_keys=True).splitlines()
    b = json.dumps(generated, indent=2, sort_keys=True).splitlines()
    sys.stderr.write(
        "MISMATCH: the schema generated from the Haskell source of truth no\n"
        "longer matches the committed oracle. Either a wire-shape change is\n"
        "intended (update schema/graph-v2-expanded.schema.json deliberately)\n"
        "or AgdaDeps.Backend.Wire drifted. Normalised diff (committed -> generated):\n\n")
    for line in difflib.unified_diff(a, b, "committed", "generated", lineterm=""):
        sys.stderr.write(line + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
