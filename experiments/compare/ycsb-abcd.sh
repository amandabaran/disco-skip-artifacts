#!/bin/bash
# disco-skip vs swarm-kv vs fusee on YCSB A, B, C, D.
#
#   ./ycsb-abcd.sh [iter] [warmup]
#
# FOUR ARMS PER WORKLOAD:
#   disco-skip --cache 1   the headline configuration
#   disco-skip --cache 0   the no-cache baseline, so what the cache contributes
#                          is visible rather than asserted
#   swarmkv
#   fusee
#
# WHY NOT E HERE. swarm-kv and fusee are not ordered structures, and neither
# implements a range: both emulate SCAN as scan_count sequential point reads on
# incremented keys (swarm-kv even drains the pipeline inside that loop, so it is
# one round trip per key). Putting an ordered scan against that would flatter us
# enormously and measure nothing. E is compared against dLSM, which is a real
# LSM tree with a real iterator -- see ycsb-e.sh.
#
# WORKLOAD D IS NOT STOCK D. Stock D is read 0.95 / insert 0.05 over `latest`.
# oops-workloadd-latest keeps `latest` but moves the 5% to update, because every
# other oops-* workload pins insertproportion=0 and D is here to isolate the
# DISTRIBUTION against B rather than to add inserts. (E does use real inserts --
# main.cpp now parses run-phase INSERT -- because there the tree growing during
# the run is the point.) See the header of the workload file.
#
# ARENA SIZING IS NOT OPTIONAL for the disco-skip arms. Every write allocates a
# vector and nothing is reclaimed, so the arena bounds run length. A run that
# exhausts its stripe reports Exhausted and the number is void; the summary
# flags it rather than letting it pass as a low result.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"

ITER=${1:-100000}
WARMUP=${2:-50000}
SERVERS=${SERVERS:-3}
# A LIST, because the figures these feed are throughput-vs-clients.
# plot-datapoints/ycsb-uniform-3x2.py sweeps client_counts on the x axis, so a
# single-client run is one point on a line chart.
CLIENT_COUNTS=(${CLIENT_COUNTS:-1 2 4 8})
VECS=${VECS:-2000000}
NODES=${NODES:-262144}
# Operations in flight per client. Left at 1 by default because FUSEE has no
# async support at all (its execute_point_op is a synchronous lambda), so 1 is
# the only setting at which all three systems are doing the same thing.
# disco-skip and swarm-kv both accept -a and both default to 1.
ASYNC=${ASYNC:-1}
# Per-operation latency timing on our arms.
#
# ON by default, because it is the FAIR setting, not the convenient one:
# swarm-kv records latency unconditionally in oops_state.hpp and fusee in its
# run loop, and neither has a switch. A disco-skip run with LATENCY=0 is
# therefore NOT comparable against them -- it is a disco-skip-only throughput
# number. Use LATENCY=0 when the figure plots throughput alone and only
# disco-skip arms matter; the log then omits the GET/PUT stats sections
# entirely, so the choice is visible in the data rather than only here.
LATENCY=${LATENCY:-1}
# How many times to repeat the whole sweep.
#
# PAPER NUMBERS NEED 3. A single sweep is n=1 and run-to-run variation is up to
# ~6% on the disco-skip arms -- and up to 17% on workload D at 2 clients, where
# the `latest` skew concentrates writes and timing matters more. A margin under
# that is not a result. Each repeat writes its own results directory; pass them
# all to summarize.py and it reports mean +- half-range and marks anything
# inside the noise band as NOISE rather than as a winner.
REPEATS=${REPEATS:-1}

# workload letter -> workload file. An explicit map, not string concatenation:
# there is no oops-workloadd-uniform (it would be byte-identical to
# oops-workloadb-uniform) and no zipfian variants exist at all, despite
# experiments/ycsb-all.sh looping over a SKEW list that includes zipfian.
declare -A WL=(
  [a]=oops-workloada-uniform
  [b]=oops-workloadb-uniform
  [c]=oops-workloadc-uniform
  [d]=oops-workloadd-latest
)
# Override to smoke a single workload: WORKLOADS=a ./ycsb-abcd.sh 2000 1000
ORDER=(${WORKLOADS:-a b c d})

# Repeats are separate RUNS, not an inner loop: each re-execs this script with
# REPEATS=1 so it gets its own stamp, its own results directory and its own
# fresh cluster setup. An inner loop sharing one directory would also share
# whatever state the previous repeat left behind, which is the opposite of what
# a repeat is for.
if [ "${REPEATS:-1}" -gt 1 ]; then
  reps=$REPEATS
  dirs=()
  for rep in $(seq 1 "$reps"); do
    echo "################ repeat $rep of $reps ################"
    REPEATS=1 "$0" "$@" || echo "repeat $rep failed; continuing"
    dirs+=("$(ls -dt "$HERE"/results/abcd-* 2>/dev/null | head -1)")
  done
  echo
  echo "All $reps repeats done. Summarise them TOGETHER -- one on its own is n=1:"
  echo "  ./summarize.py ${dirs[*]/%//results.csv}"
  exit 0
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HERE/results/abcd-$STAMP"
mkdir -p "$OUT"

{
  echo "ycsb-abcd  $STAMP"
  echo "iter=$ITER warmup=$WARMUP servers=$SERVERS clients=[${CLIENT_COUNTS[*]}] async=$ASYNC latency=$LATENCY"
  [ "$LATENCY" = 0 ] && echo "WARNING: latency timing OFF on disco-skip arms only -- NOT comparable with swarm-kv/fusee"
  echo "logs: logs/YCSB/workload-<L>/<SCHEME>/${SERVERS}servers/<nc>client/ (plot-datapoints layout)"
  echo "vecs/client=$VECS nodes/client=$NODES"
  echo "metric: SUM of per-client kops (fusee's aggregate divided by clients)"
} | tee "$OUT/params.txt"

printf "\n%-3s %-22s %8s %10s %7s %s\n" wl system clients total_kops nlogs notes \
    | tee -a "$OUT/summary.txt"

# Scheme directory names as plot-datapoints/ expects them. The existing figures
# key off logs/YCSB/workload-<LETTER>/<SCHEME>/<N>servers/<nc>client/client<c>.txt
# -- the same layout experiments/ycsb-all.sh writes -- so writing anywhere else
# means the plot scripts cannot see the run. An earlier version of this file
# used compare/<stamp>/... and produced data no existing figure could read.
declare -A SCHEME=(
  [disco-skip-cache1]=DISCO-SKIP
  [disco-skip-cache0]=DISCO-SKIP-NOCACHE
  [swarm-kv]=SWARM-KV
  [fusee]=FUSEE
)

run_arm() {
  local wl=$1 label=$2 binary=$3 system=$4 nc=$5; shift 5
  local upper; upper=$(echo "$wl" | tr '[:lower:]' '[:upper:]')
  local folder="YCSB/workload-$upper/${SCHEME[$label]}/${SERVERS}servers/${nc}client"
  local logdir="$OUT/$wl-$label-${nc}c"

  ( cd "$ROOT_DIR" && timeout 1800 ./scripts/run.sh "$binary" "$folder" \
      "${WL[$wl]}" "$SERVERS" "$nc" -I "$ITER" -W "$WARMUP" "$@" ) \
      > "$OUT/$wl-$label-${nc}c.run" 2>&1

  fetch_logs "$folder" "$nc" "$logdir"
  read -r total nlogs percsv <<<"$(total_kops "$system" "$nc" "$logdir")"
  local notes; notes=$(run_warnings "$logdir")
  [ "$nlogs" -eq 0 ] && notes="$notes NO-TPUT-PARSED"
  [ "$nlogs" -gt 0 ] && [ "$nlogs" -lt "$nc" ] && notes="$notes PARTIAL($nlogs/$nc)"

  printf "%-3s %-22s %8s %10s %7s %s\n" "$wl" "$label" "$nc" "$total" "$nlogs" \
      "$notes" | tee -a "$OUT/summary.txt"
  echo "$wl,$label,$system,$SERVERS,$nc,$total,$nlogs,\"$percsv\",\"$notes\",$ITER,$WARMUP,$ASYNC,$LATENCY" \
      >> "$OUT/results.csv"
}

# The run's parameters travel WITH the numbers. summarize.py can otherwise only
# infer that two result sets are incomparable from an implausibly wide spread --
# it caught a 100k-iter run averaged with a 5000-iter smoke that way, but only
# after the fact and only because the spread happened to be large.
echo "wl,system,binary,servers,clients,total_kops,nlogs,per_client_kops,notes,iter,warmup,async,latency" \
    > "$OUT/results.csv"

for wl in "${ORDER[@]}"; do
  for nc in "${CLIENT_COUNTS[@]}"; do
    echo "" | tee -a "$OUT/summary.txt"
    run_arm "$wl" disco-skip-cache1 disco-skip-exe disco-skip "$nc" \
        -a "$ASYNC" --latency "$LATENCY" --cache 1 \
        --vecs-per-client "$VECS" --nodes-per-client "$NODES"
    run_arm "$wl" disco-skip-cache0 disco-skip-exe disco-skip "$nc" \
        -a "$ASYNC" --latency "$LATENCY" --cache 0 \
        --vecs-per-client "$VECS" --nodes-per-client "$NODES"
    run_arm "$wl" swarm-kv swarmkv swarmkv "$nc" -a "$ASYNC"
    run_arm "$wl" fusee    fusee    fusee    "$nc"
  done
done

echo "" | tee -a "$OUT/summary.txt"
echo "results -> $OUT" | tee -a "$OUT/summary.txt"
if [ "${REPEATS:-1}" -le 1 ]; then
  echo "NOTE: this is ONE run (n=1) and is not publishable on its own." \
      | tee -a "$OUT/summary.txt"
  echo "      Use REPEATS=3, then pass all three results.csv to summarize.py." \
      | tee -a "$OUT/summary.txt"
fi
