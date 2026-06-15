#!/usr/bin/env bash
#
# build.sh - turn one CRAM into the flat artifacts the runtime serves.
#
# Heavy, one-time, offline job. Uses embedded reference sequences (via ENA
# REF_PATH) to call a consensus over the whole CRAM, packs it into
# consensus.bin + meta.json, and (optionally) precomputes per-position pileup
# columns for the hover feature.
#
# Usage:
#   scaffold/build.sh [--cram NG1C7TA6N7.mm2.sortdup.bqsr.cram] [--out artifacts] \
#       [--rate 100 | --runtime 31536000] [--start-epoch 2026-06-01T00:00:00Z] \
#       [--pileup --ref reference.fa] [--max-depth 64]
#
# Inputs: the CRAM and its .crai (auto-created if missing). Reference sequences
# are fetched from ENA using md5 tags embedded in the CRAM header.
set -euo pipefail

CRAM="NG1C7TA6N7.mm2.sortdup.bqsr.cram"
REF=""
OUT="artifacts"
RATE=""
RUNTIME="31536000"
START_EPOCH="2026-06-01T00:00:00Z"
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

FAI="${CRAM}.reference.fai"
CONSENSUS="${CRAM}.consensus.fa"

command -v samtools >/dev/null || { echo "samtools not found on PATH" >&2; exit 1; }
[[ -f "$CRAM" ]] || { echo "CRAM not found: $CRAM" >&2; exit 1; }

export REF_CACHE="${REF_CACHE:-$HOME/.cache/hts-ref/%2s/%2s/%s}"
export REF_PATH="${REF_PATH:-https://www.ebi.ac.uk/ena/cram/md5/%s}"

mkdir -p "$OUT"

echo "[1/4] ensuring indexes"
[[ -f "${CRAM}.crai" ]] || samtools index "$CRAM"

echo "[2/4] building reference index from CRAM header"
samtools view -H "$CRAM" \
  | awk '$1=="@SQ" {
      sn=""; ln="";
      for (i=1;i<=NF;i++) {
        if ($i ~ /^SN:/) sn=substr($i,4);
        if ($i ~ /^LN:/) ln=substr($i,4);
      }
      if (sn && ln) print sn "\t" ln "\t0\t60\t61";
    }' > "$FAI"

echo "[3/4] calling consensus (this is the slow part)"
samtools consensus -f fasta "$CRAM" > "$CONSENSUS"

echo "[4/4] packing consensus.bin + meta.json"
PACK_ARGS=(--fai "$FAI" --consensus "$CONSENSUS" --out "$OUT"
           --cram "$(basename "$CRAM")" --crai "${CRAM}.crai")
[[ -n "$RATE" ]] && PACK_ARGS+=(--rate "$RATE")
[[ -n "$RUNTIME" && -z "$RATE" ]] && PACK_ARGS+=(--runtime "$RUNTIME")
[[ -n "$START_EPOCH" ]] && PACK_ARGS+=(--start-epoch "$START_EPOCH")
python3 "${HERE}/pack_consensus.py" "${PACK_ARGS[@]}"

if [[ "$PILEUP" -eq 1 ]]; then
  [[ -n "$REF" ]] || { echo "--pileup requires --ref (reference FASTA for mpileup)" >&2; exit 2; }
  echo "[5/5] precomputing pileup.bin + pileup.idx (optional, large)"
  [[ -f "${REF}.fai" ]] || samtools faidx "$REF"
  samtools mpileup -f "$REF" "$CRAM" \
    | python3 "${HERE}/pack_pileup.py" --out "$OUT" --max-depth "$MAX_DEPTH"
else
  echo "skipping pileup (pass --pileup --ref reference.fa to enable the hover feature)"
fi

echo "done. artifacts in: $OUT"
ls -lh "$OUT"
