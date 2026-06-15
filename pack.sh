export REF_CACHE="$HOME/.cache/hts-ref/%2s/%2s/%s"
export REF_PATH="https://www.ebi.ac.uk/ena/cram/md5/%s"

samtools view -H NG1C7TA6N7.mm2.sortdup.bqsr.cram \
  | awk '$1=="@SQ" {
      sn=""; ln="";
      for (i=1;i<=NF;i++) {
        if ($i ~ /^SN:/) sn=substr($i,4);
        if ($i ~ /^LN:/) ln=substr($i,4);
      }
      if (sn && ln) print sn "\t" ln "\t0\t60\t61";
    }' > reference.from_cram.fai

samtools consensus \
  -f fasta \
  NG1C7TA6N7.mm2.sortdup.bqsr.cram \
  > consensus.fa

python3 ./scaffold/pack_consensus.py \
  --fai reference.from_cram.fai \
  --consensus consensus.fa \
  --out out \
  --cram NG1C7TA6N7.mm2.sortdup.bqsr.cram \
  --crai NG1C7TA6N7.mm2.sortdup.bqsr.cram.crai