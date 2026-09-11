#!/bin/bash
# disco-skip vs dLSM on YCSB E, swept over scan length.
#
#   ./ycsb-e.sh [iter] [warmup]
#
# ── READ THIS BEFORE QUOTING ANY NUMBER FROM HERE ───────────────────────────
#
# 1. OUR E DOES NOT MEASURE THE SKIP VECTOR, AND ITS TWO HALVES DO NOT EVEN
#    TOUCH THE SAME STRUCTURE. There is no skip-vector range -- A10 is deferred
#    -- so main.cpp's OpScan falls through to getFreeRangeFuture(), the register
#    RangeFuture over the OLD flat array. But OpInsert and OpPut go to
#    getFreeFuture().doPut(), which is the skip vector. Those are disjoint:
#
#      95% scan   -> register array   (never written by this workload)
#       5% insert -> skip vector      (never read by this workload)
#
#    So the insert half does NOT grow the structure being scanned, which is the
#    main thing YCSB E is for and the reason dLSM's ycsb-e is interesting. Our
#    column is therefore "95% reads of a static register array plus 5%
#    unrelated skip-vector writes". It is a register-path baseline at best and
#    must not be presented as a disco-skip E result. The genuinely useful
#    output of this script today is the dLSM column, as the target number for
#    when A10 lands.
#
#    (This also weakens the case for real inserts on our side specifically --
#    they were chosen so both sides would grow during the run, and on our side
#    they do not grow the scanned structure. Kept anyway: it costs nothing, it
#    matches dLSM's op mix, and it is the right shape for when A10 makes the
#    scan hit the skip vector.)
#
# 2. THE SCAN LENGTHS ARE MATCHED, AND THEY WERE NOT BEFORE. dLSM's ycsbc
#    hardcoded `scan_len(1, 100)`; ours set maxscanlength=8. Mean ~50 against
#    mean ~4.5 is not a comparison. dLSM now reads the bound from
#    $DLSM_SCAN_LEN_MAX (defaulting to 100, so an unset build is upstream), and
#    both sides are swept over 8 / 32 / 100. Our side also needs --maxrange
#    raised to match, because OpScan clamps len to layout.max_range and would
#    otherwise silently truncate every long scan to 10.
#
# 3. THE GENERATORS DIFFER. disco-skip drives the real YCSB Java generator and
#    parses its trace; dLSM's ycsbc has its own built-in generator. Same
#    workload DEFINITION, different draws and a different key-space layout
#    (dLSM shards keys across compute nodes). Treat these as two measurements
#    of the same workload, not as paired samples.
#
# 4. dLSM's scan_len is an 8-bit bitfield, so 255 is its ceiling. 100 is the
#    top of this sweep for that reason. (Note oops-workloade-64 in workloads/
#    actually sets maxscanlength=500 -- the filename lies, and 500 would
#    truncate on the dLSM side anyway. Not used here.)
#
# Both sides do a true 95/5 scan/insert: main.cpp now executes run-phase INSERT
# (it used to drop it silently), and dLSM's ycsb-e always did. That matters here
# more than elsewhere, because inserts make the structure GROW during the run
# and scan cost depends on how big it has become.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib.sh"

ITER=${1:-100000}
WARMUP=${2:-50000}
SERVERS=${SERVERS:-3}
CLIENTS=${CLIENTS:-1}
SCANLENS=(${SCANLENS:-8 32 100})
# 5% of a 1M-op workload is 50k inserts, each allocating a vector, plus splits,
# plus the 100k loaded keys. Sized well past that.
VECS=${VECS:-2000000}
NODES=${NODES:-262144}

# dLSM side.
#
# MATCHED TO OUR SPLIT ON PURPOSE. run_ycsb.sh defaults to 1 memory node and 5
# compute nodes; against a 1-client disco-skip run that is 5 nodes x THREADS
# threads versus one client, i.e. a hardware difference reported as a
# throughput difference. config.sh puts servers on w1.. and clients on w5.., so
# memory nodes mirror SERVERS and compute nodes mirror CLIENTS.
DLSM_THREADS=${DLSM_THREADS:-1}
DLSM_COROS=${DLSM_COROS:-4}
DLSM_MEM_NODES=${DLSM_MEM_NODES:-$(seq -s' ' 1 "$SERVERS")}
DLSM_COMPUTE_NODES=${DLSM_COMPUTE_NODES:-$(seq -s' ' 5 $((4 + CLIENTS)))}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HERE/results/e-$STAMP"
mkdir -p "$OUT"

{
  echo "ycsb-e  $STAMP"
  echo "iter=$ITER warmup=$WARMUP servers=$SERVERS clients=$CLIENTS"
  echo "scan lengths: ${SCANLENS[*]}"
  echo "dlsm: mem=[$DLSM_MEM_NODES] compute=[$DLSM_COMPUTE_NODES] threads=$DLSM_THREADS"
  echo "NOTE: the disco-skip column is the REGISTER range path, not the skip"
  echo "      vector (A10 deferred). See the header of this script."
} | tee "$OUT/params.txt"

printf "\n%-6s %-20s %10s %7s %s\n" scanlen system total_kops nlogs notes \
    | tee -a "$OUT/summary.txt"
echo "scanlen,system,servers,clients,total_kops,nlogs,per_client_kops,notes" \
    > "$OUT/results.csv"

run_ours() {
  local n=$1
  local label="disco-skip-reg"
  local folder="compare/e-$STAMP/scan$n/$label"
  local logdir="$OUT/scan$n-$label"

  ( cd "$ROOT_DIR" && timeout 1800 ./scripts/run.sh disco-skip-exe "$folder" \
      "oops-workloade-scan$n" "$SERVERS" "$CLIENTS" \
      -I "$ITER" -W "$WARMUP" --cache 1 \
      --maxrange "$n" \
      --vecs-per-client "$VECS" --nodes-per-client "$NODES" ) \
      > "$OUT/scan$n-$label.run" 2>&1

  fetch_logs "$folder" "$CLIENTS" "$logdir"
  read -r total nlogs percsv <<<"$(total_kops disco-skip "$CLIENTS" "$logdir")"
  local notes; notes=$(run_warnings "$logdir")
  [ "$nlogs" -eq 0 ] && notes="$notes NO-TPUT-PARSED"
  notes="$notes register-path-not-skipvector"

  printf "%-6s %-20s %10s %7s %s\n" "$n" "$label" "$total" "$nlogs" "$notes" \
      | tee -a "$OUT/summary.txt"
  echo "$n,$label,$SERVERS,$CLIENTS,$total,$nlogs,\"$percsv\",\"$notes\"" \
      >> "$OUT/results.csv"
}

run_dlsm() {
  local n=$1
  local log="$OUT/scan$n-dlsm.run"
  # DLSM_SCAN_LEN_MAX reaches the remote ycsbc because run_ycsb.sh now
  # interpolates it into the ssh command line; exporting it here alone would
  # leave every arm at the upstream default of 100.
  ( cd "$ROOT_DIR" && DLSM_SCAN_LEN_MAX="$n" \
      MEM_NODES="$DLSM_MEM_NODES" COMPUTE_NODES="$DLSM_COMPUTE_NODES" \
      timeout 1800 \
      ./experiments/dlsm/run_ycsb.sh ycsb-e uniform "$DLSM_THREADS" ) \
      > "$log" 2>&1

  # run_ycsb.sh echoes the tag it used and scps the per-node logs into
  # logs/dlsm/. The tag carries the scan length, so arms cannot be confused.
  local tag
  tag=$(grep -oE 'dLSM/YCSB: [^ ]+' "$log" | head -1 | awk '{print $2}')
  local nodelogs=()
  if [ -n "$tag" ]; then
    mapfile -t nodelogs < <(ls "$ROOT_DIR"/logs/dlsm/ycsbc_"$tag"_w*.log 2>/dev/null)
  fi

  # ycsbc prints "# Transaction throughput (MOPS): <float>" PER COMPUTE NODE --
  # the formula divides tran_ops by compute_nodes.size(), and its
  # /num_threads*num_threads cancels. So the cluster figure is the SUM over
  # nodes, and it is in MOPS where our side reports kops: x1000.
  local total_kops=0 cnt=0 percsv="" f v
  for f in "${nodelogs[@]}"; do
    [ -s "$f" ] || continue
    v=$(grep -oE '# Transaction throughput \(MOPS\): [0-9.e+-]+' "$f" \
        | awk '{print $NF}' | tail -1)
    [ -n "$v" ] || continue
    local kops
    kops=$(awk -v x="$v" 'BEGIN{printf "%d", x*1000}')
    total_kops=$(( total_kops + kops )); cnt=$(( cnt + 1 ))
    percsv="${percsv}${percsv:+,}${kops}"
  done

  local notes=""
  [ "$cnt" -eq 0 ] && notes="NO-TPUT-PARSED(tag=${tag:-none})"
  grep -qiE "ERROR|Segmentation|assert" "$log" 2>/dev/null && notes="$notes ERRORS-IN-LOG"

  printf "%-6s %-20s %10s %7s %s\n" "$n" "dlsm-ycsbc" "$total_kops" "$cnt" "$notes" \
      | tee -a "$OUT/summary.txt"
  echo "$n,dlsm-ycsbc,,,$total_kops,$cnt,\"$percsv\",\"$notes\"" >> "$OUT/results.csv"
}

for n in "${SCANLENS[@]}"; do
  echo "" | tee -a "$OUT/summary.txt"
  run_ours "$n"
  run_dlsm "$n"
done

echo "" | tee -a "$OUT/summary.txt"
echo "results -> $OUT" | tee -a "$OUT/summary.txt"
