#!/usr/bin/env python3
"""Pack a reference-ordered consensus FASTA into the flat artifacts the runtime serves.

Outputs (into --out):
  consensus.bin   1 byte per reference position (ASCII base: A/C/G/T/N/...), all
                  contigs concatenated in reference (.fai) order.
  meta.json       N (total length), contig offset table, source info, default pacing.

The consensus FASTA is streamed one record at a time, so peak memory is ~one
chromosome. We trust that the FASTA contains contigs in reference order (this is
how `samtools consensus` emits them); any reference contig that is missing from
the FASTA (e.g. zero coverage) is filled with N for its full length so that the
coordinate space always matches the reference exactly.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import sys


def read_fai(path):
    """Return [(name, length), ...] in file order from a .fai index."""
    contigs = []
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            contigs.append((parts[0], int(parts[1])))
    return contigs


def iter_fasta(path):
    """Yield (name, bytearray(sequence)) for each record, uppercased, streaming."""
    name = None
    seq = bytearray()
    with open(path, "rb") as fh:
        for raw in fh:
            if raw.startswith(b">"):
                if name is not None:
                    yield name, seq
                header = raw[1:].split(None, 1)[0]
                name = header.decode("ascii", "replace")
                seq = bytearray()
            else:
                seq += raw.strip().upper()
    if name is not None:
        yield name, seq


def fit_to_length(seq: bytearray, length: int) -> bytearray:
    """Pad with N or trim so the sequence is exactly `length` bytes."""
    if len(seq) < length:
        seq += b"N" * (length - len(seq))
    elif len(seq) > length:
        del seq[length:]
    return seq


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fai", required=True, help="reference FASTA .fai index")
    ap.add_argument("--consensus", required=True, help="consensus FASTA from samtools consensus")
    ap.add_argument("--out", required=True, help="output artifacts directory")
    ap.add_argument("--cram", default=None, help="source CRAM filename (recorded in meta)")
    ap.add_argument("--crai", default=None, help="source .crai path (sha256 recorded in meta)")
    ap.add_argument("--rate", type=float, default=None, help="default reveal rate (bases/sec)")
    ap.add_argument("--runtime", type=float, default=None, help="default total runtime (seconds)")
    ap.add_argument("--start-epoch", default=None, help="default start time (unix seconds or RFC3339)")
    args = ap.parse_args(argv)

    if args.rate and args.runtime:
        ap.error("set at most one of --rate / --runtime")

    os.makedirs(args.out, exist_ok=True)
    fai = read_fai(args.fai)
    fai_len = {n: l for n, l in fai}
    order = [n for n, _ in fai]

    consensus_path = os.path.join(args.out, "consensus.bin")
    contigs = []
    total = 0
    idx = 0  # pointer into the reference order

    def fill_missing_until(target_name, out):
        nonlocal idx, total
        while idx < len(order) and order[idx] != target_name:
            name = order[idx]
            length = fai_len[name]
            contigs.append({"name": name, "start": total, "length": length})
            # write N for an entirely uncovered contig in CHUNK-sized blocks
            block = b"N" * (1 << 20)
            remaining = length
            while remaining > 0:
                w = min(remaining, len(block))
                out.write(block[:w])
                remaining -= w
            total += length
            idx += 1

    with open(consensus_path, "wb") as out:
        for name, seq in iter_fasta(args.consensus):
            if name not in fai_len:
                sys.exit(f"contig {name!r} from consensus is not in the reference .fai")
            fill_missing_until(name, out)
            if idx >= len(order) or order[idx] != name:
                sys.exit(f"consensus contig order does not match reference order at {name!r}")
            length = fai_len[name]
            seq = fit_to_length(seq, length)
            out.write(seq)
            contigs.append({"name": name, "start": total, "length": length})
            total += length
            idx += 1
        # any trailing reference contigs absent from the consensus -> all N
        while idx < len(order):
            name = order[idx]
            length = fai_len[name]
            contigs.append({"name": name, "start": total, "length": length})
            block = b"N" * (1 << 20)
            remaining = length
            while remaining > 0:
                w = min(remaining, len(block))
                out.write(block[:w])
                remaining -= w
            total += length
            idx += 1

    meta = {
        "version": 1,
        "n": total,
        "contigs": contigs,
        "pileup": False,
        "source": {
            "cram": args.cram,
            "crai_sha256": sha256_file(args.crai) if args.crai else None,
        },
        "build": {
            "tool": "samtools consensus",
            "built_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        },
        "pacing": {
            "start_epoch": args.start_epoch,
            "rate_bases_per_sec": args.rate,
            "runtime_seconds": args.runtime,
        },
    }
    with open(os.path.join(args.out, "meta.json"), "w") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")

    print(f"wrote {consensus_path} ({total} bases across {len(contigs)} contigs)")
    print(f"wrote {os.path.join(args.out, 'meta.json')}")


if __name__ == "__main__":
    main()
