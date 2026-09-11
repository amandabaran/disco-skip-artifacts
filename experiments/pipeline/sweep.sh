#!/usr/bin/env bash
# Sweep async parallelism for the skip-vector path.
#
#   ./sweep.sh [iter] [warmup]
#
# THE QUESTION: does having many operations in flight raise throughput? Until
# the futures landed the client was synchronous -- main.cpp drained every future
# after every operation -- so async parallelism did nothing at all. This measures
# whether it does now.
#
# ARENA SIZING IS NOT OPTIONAL. Every write allocates a vector and nothing is
# reclaimed (invariants.md §5), so the arena bounds run length rather than the
# other way round. The smoke run used 135,647 vectors for a ~100k-key population
# plus 2,000 operations, i.e. ~1.35 per put once splits are counted. A run that
# exhausts its stripe reports Exhausted and the numbers become meaningless, so
# these are sized well past what the longest arm needs.
#
# Results land in results/<timestamp>/, one log per arm, plus a summary.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

ITER=${1:-100000}
WARMUP=${2:-50000}
PARALLEL=(1 2 4 8 16 32)
VECS=2000000
NODES=262144

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HERE/results/$STAMP"
mkdir -p "$OUT"

echo "sweep: iter=$ITER warmup=$WARMUP vecs/client=$VECS" | tee "$OUT/params.txt"

run_arm() {
  local label=$1 workload=$2 cache=$3 async=$4
  local folder="pipeline/$STAMP/$label"
  cd "$ROOT"
  timeout 900 ./scripts/run.sh disco-skip-exe "$folder" "$workload" 1 1 \
      -a "$async" -I "$ITER" -W "$WARMUP" --cache "$cache" \
      --vecs-per-client "$VECS" --nodes-per-client "$NODES" \
      > "$OUT/$label.run" 2>&1
  # The client log is on w5; the run script only tees locally on the worker.
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 w5 \
      "cat $ROOT/logs/$folder/client1.txt" > "$OUT/$label.log" 2>/dev/null

  local tput note=""
  tput=$(grep -oE 'Local tput: [0-9]+' "$OUT/$label.log" | grep -oE '[0-9]+$')

  # grep -q, not grep -c. `grep -c` prints 0 AND exits non-zero when nothing
  # matches, so $(grep -c ... || echo 0) captures both zeros and compares
  # "0\n0" against "0" -- which never matches, so EVERY arm was flagged as
  # exhausted. Caught on the second arm. Worth the note because the failure
  # mode was to void perfectly good numbers rather than to look broken.
  if grep -qi exhaust "$OUT/$label.log" 2>/dev/null; then
    note="(ARENA EXHAUSTED -- number is void)"
  fi

  # Report arena headroom regardless, so the sizing can be checked rather than
  # assumed to have been adequate.
  local used
  used=$(grep -oE 'vectors allocated: +[0-9]+ of [0-9]+' "$OUT/$label.log" \
         | grep -oE '[0-9]+ of [0-9]+')
  printf "%-20s %-24s cache=%s a=%-3s tput=%-8s vecs=%-18s %s\n" \
      "$label" "$workload" "$cache" "$async" "${tput:-FAILED}" \
      "${used:-?}" "$note" | tee -a "$OUT/summary.txt"
}

echo | tee -a "$OUT/summary.txt"
echo "--- workloada (50% read / 50% update), cache on ---" | tee -a "$OUT/summary.txt"
for a in "${PARALLEL[@]}"; do run_arm "a-cache1-p$a" oops-workloada-uniform 1 "$a"; done

echo | tee -a "$OUT/summary.txt"
echo "--- workloadc (100% read), cache on ---" | tee -a "$OUT/summary.txt"
for a in "${PARALLEL[@]}"; do run_arm "c-cache1-p$a" oops-workloadc-uniform 1 "$a"; done

echo | tee -a "$OUT/summary.txt"
echo "--- cache off, for the no-cache baseline ---" | tee -a "$OUT/summary.txt"
for a in 1 8 32; do run_arm "a-cache0-p$a" oops-workloada-uniform 0 "$a"; done
for a in 1 8 32; do run_arm "c-cache0-p$a" oops-workloadc-uniform 0 "$a"; done

echo
echo "results -> $OUT"
