#!/usr/bin/env bash
#
# build.sh - turn one CRAM into the flat artifacts the runtime serves.
#
# Heavy, one-time, offline job. Runs samtools to call a consensus over the whole
# CRAM, packs it into consensus.bin + meta.json, and (optionally) precomputes the
# per-position pileup columns for the hover feature.
#
# Usage:
#   scaffold/build.sh --cram sample.cram --ref reference.fa --out artifacts \
#       [--rate 100 | --runtime 31536000] [--start-epoch 2026-07-01T00:00:00Z] \
#       [--pileup] [--max-depth 64]
#
# Inputs: the CRAM, its .crai (auto-created if missing), and the reference FASTA
# (its .fai is auto-created if missing). The reference is mandatory - a CRAM
# cannot be decoded without it.
set -euo pipefail

CRAM=""
REF=""
OUT="artifacts"
RATE=""
RUNTIME=""
START_EPOCH=""
PILEUP=0
MAX_DEPTH=64

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cram) CRAM="$2"; shift 2;;
    --ref) REF="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --rate) RATE="$2"; shift 2;;
    --runtime) RUNTIME="$2"; shift 2;;
    --start-epoch) START_EPOCH="$2"; shift 2;;
    --pileup) PILEUP=1; shift;;
    --max-depth) MAX_DEPTH="$2"; shift 2;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[[ -n "$CRAM" ]] || { echo "--cram is required" >&2; exit 2; }
[[ -n "$REF" ]] || { echo "--ref is required" >&2; exit 2; }
command -v samtools >/dev/null || { echo "samtools not found on PATH" >&2; exit 1; }

mkdir -p "$OUT"

echo "[1/4] ensuring indexes"
[[ -f "${REF}.fai" ]] || samtools faidx "$REF"
[[ -f "${CRAM}.crai" ]] || samtools index "$CRAM"

echo "[2/4] calling consensus (this is the slow part)"
CONSENSUS_FA="${OUT}/consensus.fa"
samtools consensus --reference "$REF" -f fasta -o "$CONSENSUS_FA" "$CRAM"

echo "[3/4] packing consensus.bin + meta.json"
PACK_ARGS=(--fai "${REF}.fai" --consensus "$CONSENSUS_FA" --out "$OUT"
           --cram "$(basename "$CRAM")" --crai "${CRAM}.crai")
[[ -n "$RATE" ]] && PACK_ARGS+=(--rate "$RATE")
[[ -n "$RUNTIME" ]] && PACK_ARGS+=(--runtime "$RUNTIME")
[[ -n "$START_EPOCH" ]] && PACK_ARGS+=(--start-epoch "$START_EPOCH")
python3 "${HERE}/pack_consensus.py" "${PACK_ARGS[@]}"
rm -f "$CONSENSUS_FA"

if [[ "$PILEUP" -eq 1 ]]; then
  echo "[4/4] precomputing pileup.bin + pileup.idx (optional, large)"
  samtools mpileup -f "$REF" "$CRAM" \
    | python3 "${HERE}/pack_pileup.py" --out "$OUT" --max-depth "$MAX_DEPTH"
else
  echo "[4/4] skipping pileup (pass --pileup to enable the hover feature)"
fi

echo "done. artifacts in: $OUT"
ls -lh "$OUT"
