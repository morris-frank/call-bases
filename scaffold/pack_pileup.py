#!/usr/bin/env python3
"""Pack per-position pileup columns for the optional hover feature.

Reads `samtools mpileup` on stdin (in reference/coordinate order) and writes:
  pileup.bin   concatenated read bases (1 ASCII byte each, A/C/G/T/N) per position,
               depth-capped at --max-depth.
  pileup.idx   little-endian uint64 array of length N+1; positions p occupy the
               byte range [idx[p], idx[p+1]) of pileup.bin. Uncovered positions
               have idx[p] == idx[p+1] (zero depth).

It also flips meta.pileup to true so the runtime auto-enables the feature.

Coordinate space is taken from meta.json (written by pack_consensus.py): the
global index of a record is contig_start + (pos - 1). Positions with no coverage
are filled with empty columns so the index always covers exactly N positions.

This keeps the runtime a dumb offset reader: pileup at position p is just a slice
of pileup.bin addressed by two uint64 reads from pileup.idx.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys


def parse_bases(raw: str, ref: str, max_depth: int) -> str:
    """Turn an mpileup bases column into plain ACGTN read bases, depth-capped.

    Handles '.'/',' (ref match), ACGTNacgtn (mismatch), '^X' (read-start +
    mapping-quality char), '$' (read-end), '+N<seq>' / '-N<seq>' (indels), and
    '*' (deletion placeholder, dropped to keep a clean alphabet).
    """
    out = []
    i = 0
    n = len(raw)
    ref = ref.upper()
    while i < n and len(out) < max_depth:
        c = raw[i]
        if c == "^":
            i += 2  # skip the caret and the following mapping-quality char
            continue
        if c == "$":
            i += 1
            continue
        if c in "+-":
            i += 1
            num = ""
            while i < n and raw[i].isdigit():
                num += raw[i]
                i += 1
            i += int(num) if num else 0  # skip the indel sequence
            continue
        if c in ".,":
            out.append(ref if ref in "ACGT" else "N")
            i += 1
            continue
        if c in "ACGTNacgtn":
            out.append(c.upper())
            i += 1
            continue
        # '*' deletions and anything else: ignore
        i += 1
    return "".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True, help="artifacts directory (must contain meta.json)")
    ap.add_argument("--max-depth", type=int, default=64, help="cap stored read bases per position")
    args = ap.parse_args(argv)

    meta_path = os.path.join(args.out, "meta.json")
    with open(meta_path) as fh:
        meta = json.load(fh)
    n_total = meta["n"]
    contig_start = {c["name"]: c["start"] for c in meta["contigs"]}

    bin_path = os.path.join(args.out, "pileup.bin")
    idx_path = os.path.join(args.out, "pileup.idx")

    offset = 0
    cursor = 0  # next global position whose idx entry must be written

    with open(bin_path, "wb") as binf, open(idx_path, "wb") as idxf:
        def write_idx(o):
            idxf.write(struct.pack("<Q", o))

        for line in sys.stdin:
            line = line.rstrip("\n")
            if not line:
                continue
            cols = line.split("\t")
            if len(cols) < 5:
                continue
            chrom, pos_s, ref = cols[0], cols[1], cols[2]
            raw_bases = cols[4]
            if chrom not in contig_start:
                continue
            g = contig_start[chrom] + (int(pos_s) - 1)
            if g < cursor or g >= n_total:
                # out-of-order or out-of-range record; skip defensively
                continue
            # fill uncovered gap positions with zero-depth idx entries
            while cursor < g:
                write_idx(offset)
                cursor += 1
            bases = parse_bases(raw_bases, ref, args.max_depth)
            write_idx(offset)  # idx[g]
            cursor += 1
            payload = bases.encode("ascii")
            binf.write(payload)
            offset += len(payload)

        # remaining uncovered tail
        while cursor < n_total:
            write_idx(offset)
            cursor += 1
        write_idx(offset)  # final sentinel idx[N]

    meta["pileup"] = True
    meta.setdefault("build", {})["pileup_max_depth"] = args.max_depth
    with open(meta_path, "w") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")

    print(f"wrote {bin_path} ({offset} read bases)")
    print(f"wrote {idx_path} ({n_total + 1} offsets)")
    print(f"updated {meta_path}: pileup=true (max_depth={args.max_depth})")


if __name__ == "__main__":
    main()
