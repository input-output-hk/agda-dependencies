#!/usr/bin/env python3
"""Acceptance gate for ``--packed-analytical``.

Decodes a packed-analytical ``graph.json`` and asserts that, node-for-node,
it carries the *same* per-definition analytical fields the expanded form
of the same corpus does: kind, line, access, type (``--with-signatures``),
and subterm hashes/depths (``--with-term-hashes``). This is the
definition of done for the packed-complete work — packed must lose no
fidelity vs. expanded.

Usage:
    packed_analytical_check.py <packed.json> <expanded.json>
"""
import base64
import json
import struct
import sys

KINDS = ["function", "projection", "datatype", "record",
         "constructor", "postulate", "primitive", "other"]
ACCESS = {0: None, 1: "public", 2: "private"}
# Bit layout of the packed ``defs.unsafe`` Int8 bitmask; MUST match
# AgdaDeps.Backend.GraphJson.encodeUnsafeByte.
UNSAFE_BITS = [(1, "non-terminating"), (2, "trustme")]


def unsafe_from_byte(b):
    """Decode one packed unsafe bitmask byte to a sorted tag-name list."""
    return sorted(name for bit, name in UNSAFE_BITS if b & bit)


def dec(b64, fmt, size):
    raw = base64.b64decode(b64)
    assert len(raw) % size == 0, f"ragged {fmt} array"
    return [struct.unpack_from(fmt, raw, i)[0] for i in range(0, len(raw), size)]


def decode_packed(g):
    d = g["defs"]
    names = d["names"]
    n = len(names)
    kinds = dec(d["kinds"], "<b", 1)
    lines = dec(d["lines"], "<i", 4)
    access = dec(d["access"], "<b", 1)
    # `unsafe` is always present in fresh packed-analytical output; guard
    # for absence so this stays runnable against older output.
    unsafe = dec(d["unsafe"], "<b", 1) if "unsafe" in d else [0] * n
    types = d.get("types")  # [str|null] or absent
    # subterm CSR (absent unless --with-term-hashes)
    if "subtermOffsets" in d:
        offs = dec(d["subtermOffsets"], "<i", 4)
        flatH = dec(d["subtermHashes"], "<Q", 8)
        flatD = dec(d["subtermDepths"], "<i", 4)
        assert len(offs) == n + 1, f"subtermOffsets len {len(offs)} != {n}+1"
    else:
        offs = flatH = flatD = None
    out = {}
    for i, name in enumerate(names):
        rec = {
            "kind": KINDS[kinds[i]],
            "line": (None if lines[i] == -1 else lines[i]),
            "access": ACCESS[access[i]],
            "type": (types[i] if types is not None else None),
            "unsafe": unsafe_from_byte(unsafe[i]),
        }
        if offs is not None:
            a, b = offs[i], offs[i + 1]
            rec["hashes"] = flatH[a:b]
            rec["depths"] = flatD[a:b]
        out[name] = rec
    return out, (offs is not None), (types is not None)


def decode_expanded(g):
    defs = g["definitions"]
    sh = g.get("definitionSubtermHashes")
    sd = g.get("definitionSubtermDepths")
    out = {}
    for i, d in enumerate(defs):
        rec = {
            "kind": d["kind"],
            "line": d.get("line"),
            "access": d.get("access"),
            "type": d.get("type"),
            "unsafe": sorted(d.get("unsafe", [])),
        }
        if sh is not None:
            rec["hashes"] = sh[i]
            rec["depths"] = sd[i]
        out[d["name"]] = rec
    return out, (sh is not None)


def main():
    packed = json.load(open(sys.argv[1]))
    expanded = json.load(open(sys.argv[2]))
    pdefs, p_has_sub, p_has_types = decode_packed(packed)
    edefs, e_has_sub = decode_expanded(expanded)

    if set(pdefs) != set(edefs):
        only_p = sorted(set(pdefs) - set(edefs))[:5]
        only_e = sorted(set(edefs) - set(pdefs))[:5]
        sys.exit(f"node-set mismatch: packed-only={only_p} expanded-only={only_e}")

    mismatches = []
    for name in pdefs:
        p, e = pdefs[name], edefs[name]
        for f in ("kind", "line", "access", "type", "unsafe"):
            if p[f] != e[f]:
                mismatches.append(f"{name}.{f}: packed={p[f]!r} expanded={e[f]!r}")
        if p_has_sub and e_has_sub:
            if p["hashes"] != e["hashes"]:
                mismatches.append(f"{name}.hashes: {p['hashes']} != {e['hashes']}")
            if p["depths"] != e["depths"]:
                mismatches.append(f"{name}.depths: {p['depths']} != {e['depths']}")

    if mismatches:
        print(f"MISMATCH ({len(mismatches)}):")
        for m in mismatches[:30]:
            print("  " + m)
        sys.exit(1)
    print(f"OK: packed-analytical ≡ expanded over {len(pdefs)} defs "
          f"(subterms={'yes' if p_has_sub else 'no'}, "
          f"types={'yes' if p_has_types else 'no'}).")


if __name__ == "__main__":
    main()
