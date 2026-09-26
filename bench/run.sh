#!/usr/bin/env bash
# Benchmark zigote against other FASTA parsers.
# usage: PYTHON=/path/to/python3 bench/run.sh [extra.fa ...]   (run from the repo root)
#
# PYTHON must have needletail, biopython and pyfastx installed. seqtk is taken
# from the same environment unless SEQTK is set.
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON=${PYTHON:-python3}
SEQTK=${SEQTK:-$(dirname "$(command -v "$PYTHON")")/seqtk}
DATA=bench/data
RESULTS=bench/results
mkdir -p "$DATA" "$RESULTS"

zig build -Doptimize=ReleaseFast
cargo build --release --quiet --manifest-path bench/rust-parsers/Cargo.toml
cc -O3 -o bench/kseq/count bench/kseq/count.c -lz
cc -O3 -DPLAIN_READ -o bench/kseq/count-read bench/kseq/count.c -lz

ZIGOTE=zig-out/bin/zigote
RUST=bench/rust-parsers/target/release/rust-bench
RUST_PARSERS=(needletail seq_io seq_io-lines paraseq noodles rust-bio)

[[ -f $DATA/long.fa ]] || "$PYTHON" bench/gen_fasta.py long "$DATA/long.fa"
[[ -f $DATA/short.fa ]] || "$PYTHON" bench/gen_fasta.py short "$DATA/short.fa"

datasets=("$DATA/long.fa" "$DATA/short.fa" "$@")

# Every parser must report the same record and residue counts before timing.
counts() {
  local f=$1
  echo "zigote $("$ZIGOTE" --parse-only "$f" | awk '{print $2}' | paste -sd' ' -)"
  echo "kseq $(bench/kseq/count "$f")"
  echo "kseq-read $(bench/kseq/count-read "$f")"
  echo "seqtk $("$SEQTK" size "$f" | tr '\t' ' ')"
  for p in "${RUST_PARSERS[@]}"; do echo "$p $("$RUST" "$p" "$f")"; done
  echo "needletail-py $("$PYTHON" bench/needletail_py.py "$f")"
  echo "biopython $("$PYTHON" bench/biopython_count.py "$f")"
  echo "pyfastx $("$PYTHON" bench/pyfastx_count.py "$f")"
  echo "seqkit $(seqkit stats -T "$f" | tail -1 | cut -f4,5 | tr '\t' ' ')"
  samtools faidx "$f"
  echo "samtools-faidx $(awk '{n++; s+=$2} END {print n, s}' "$f.fai")"
  rm -f "$f.fai"
}

for f in "${datasets[@]}"; do
  echo "== $f"
  out=$(counts "$f")
  echo "$out" | column -t
  if [[ $(echo "$out" | awk '{print $2, $3}' | sort -u | wc -l) -ne 1 ]]; then
    echo "count mismatch on $f; not timing" >&2
    exit 1
  fi
done

# Same warmup and run count for every command; -N runs without a shell.
HF=(hyperfine -N --warmup 3 --runs 30 --style basic)

for f in "${datasets[@]}"; do
  name=$(basename "$f" .fa)
  native=(
    -n zigote "$ZIGOTE --parse-only $f"
    -n kseq "bench/kseq/count $f"
    -n kseq-read "bench/kseq/count-read $f"
    -n seqtk "$SEQTK size $f"
  )
  for p in "${RUST_PARSERS[@]}"; do native+=(-n "$p" "$RUST $p $f"); done
  native+=(-n seqkit "seqkit stats $f" -n cat-floor "cat $f")
  "${HF[@]}" --export-markdown "$RESULTS/$name-native.md" --export-json "$RESULTS/$name-native.json" "${native[@]}"

  "${HF[@]}" --export-markdown "$RESULTS/$name-python.md" --export-json "$RESULTS/$name-python.json" \
    -n needletail-py "$PYTHON bench/needletail_py.py $f" \
    -n biopython "$PYTHON bench/biopython_count.py $f" \
    -n pyfastx "$PYTHON bench/pyfastx_count.py $f" \
    -n python-startup "$PYTHON -c pass"

  # faidx builds an index file rather than reading records in order.
  "${HF[@]}" --prepare "rm -f $f.fai" \
    --export-markdown "$RESULTS/$name-faidx.md" --export-json "$RESULTS/$name-faidx.json" \
    -n samtools-faidx "samtools faidx $f"
  rm -f "$f.fai"
done
