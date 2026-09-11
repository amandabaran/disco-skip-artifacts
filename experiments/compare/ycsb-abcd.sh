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
CLIENTS=${CLIENTS:-1}
VECS=${VECS:-2000000}
NODES=${NODES:-262144}

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

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HERE/results/abcd-$STAMP"
mkdir -p "$OUT"

{
  echo "ycsb-abcd  $STAMP"
  echo "iter=$ITER warmup=$WARMUP servers=$SERVERS clients=$CLIENTS"
  echo "vecs/client=$VECS nodes/client=$NODES"
  echo "metric: SUM of per-client kops (fusee's aggregate divided by clients)"
} | tee "$OUT/params.txt"

printf "\n%-3s %-22s %10s %7s %s\n" wl system total_kops nlogs notes \
    | tee -a "$OUT/summary.txt"

run_arm() {
  local wl=$1 label=$2 binary=$3 system=$4; shift 4
  local folder="compare/abcd-$STAMP/$wl/$label"
  local logdir="$OUT/$wl-$label"

  ( cd "$ROOT_DIR" && timeout 1200 ./scripts/run.sh "$binary" "$folder" \
      "${WL[$wl]}" "$SERVERS" "$CLIENTS" -I "$ITER" -W "$WARMUP" "$@" ) \
      > "$OUT/$wl-$label.run" 2>&1

  fetch_logs "$folder" "$CLIENTS" "$logdir"
  read -r total nlogs percsv <<<"$(total_kops "$system" "$CLIENTS" "$logdir")"
  local notes; notes=$(run_warnings "$logdir")
  [ "$nlogs" -eq 0 ] && notes="$notes NO-TPUT-PARSED"
  [ "$nlogs" -gt 0 ] && [ "$nlogs" -lt "$CLIENTS" ] && notes="$notes PARTIAL($nlogs/$CLIENTS)"

  printf "%-3s %-22s %10s %7s %s\n" "$wl" "$label" "$total" "$nlogs" "$notes" \
      | tee -a "$OUT/summary.txt"
  echo "$wl,$label,$system,$SERVERS,$CLIENTS,$total,$nlogs,\"$percsv\",\"$notes\"" \
      >> "$OUT/results.csv"
}

echo "wl,system,binary,servers,clients,total_kops,nlogs,per_client_kops,notes" \
    > "$OUT/results.csv"

for wl in "${ORDER[@]}"; do
  echo "" | tee -a "$OUT/summary.txt"
  run_arm "$wl" disco-skip-cache1 disco-skip-exe disco-skip \
      --cache 1 --vecs-per-client "$VECS" --nodes-per-client "$NODES"
  run_arm "$wl" disco-skip-cache0 disco-skip-exe disco-skip \
      --cache 0 --vecs-per-client "$VECS" --nodes-per-client "$NODES"
  run_arm "$wl" swarm-kv swarmkv swarmkv
  run_arm "$wl" fusee    fusee    fusee
done

echo "" | tee -a "$OUT/summary.txt"
echo "results -> $OUT" | tee -a "$OUT/summary.txt"
