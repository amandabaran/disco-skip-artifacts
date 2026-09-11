#!/usr/bin/env bash
# Drive counter_bench across the cluster.
#
#   ./run_hotspot.sh sweep                 # the full comparison (default)
#   ./run_hotspot.sh one faa 4 0           # op, client machines, stride
#
# The server runs on w1 and holds the single memory region; client PROCESSES
# run one per machine on w2, w3, ... and all connect into that one server
# process, so with stride=0 every QP on every machine operates on the SAME
# 8-byte word. That is the configuration ib_atomic_bw cannot produce, and the
# whole reason this exists.
#
# Read stride=0 against stride=64 rather than either alone: the pair separates
# "the shared word serialises" from "the NIC is at its issue rate anyway".
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SERVER=w1
SERVER_IP=10.10.1.1
ALL_CLIENTS=(w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12)

QPS=${QPS:-8}
DEPTH=${DEPTH:-16}
SECS=${SECS:-5}
PORT_BASE=${PORT_BASE:-18600}

SSH=(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)
REMOTE_DIR=/tmp/rdma-counter

build() {
  echo "building on $SERVER and ${#ALL_CLIENTS[@]} clients..."
  for h in "$SERVER" "${ALL_CLIENTS[@]}"; do
    (
      "${SSH[@]}" "$h" "mkdir -p $REMOTE_DIR" 2>/dev/null
      # w5's control-network link drops connections intermittently; retry.
      for attempt in 1 2 3; do
        scp -q -o StrictHostKeyChecking=no -o BatchMode=yes \
            "$HERE/counter_bench.c" "$HERE/Makefile" "$h:$REMOTE_DIR/" && break
        sleep 2
      done
      "${SSH[@]}" "$h" "cd $REMOTE_DIR && make -s" 2>&1 | sed "s/^/[$h] /"
    ) &
  done
  wait
  echo "build done"
}

# one <op> <n_client_machines> <stride> -> prints the aggregate
one() {
  local op=$1 nc=$2 stride=$3
  local port=$((PORT_BASE + RANDOM % 400))
  local clients=("${ALL_CLIENTS[@]:0:$nc}")
  local out; out=$(mktemp -d)

  "${SSH[@]}" "$SERVER" \
    "cd $REMOTE_DIR && ./counter_bench --server --clients $nc --port $port" \
    > "$out/server.txt" 2>&1 &
  local srv_wait=$!
  sleep 2

  for h in "${clients[@]}"; do
    "${SSH[@]}" "$h" \
      "cd $REMOTE_DIR && ./counter_bench --client $SERVER_IP --op $op \
       --qps $QPS --depth $DEPTH --secs $SECS --stride $stride --port $port" \
      > "$out/$h.txt" 2>&1 &
  done
  wait $srv_wait 2>/dev/null
  wait

  # Sum the machine-readable RESULT lines.
  local total ok
  total=$(grep -h '^RESULT' "$out"/*.txt 2>/dev/null \
          | sed 's/.*mops=//' | awk '{s+=$1} END {printf "%.4f", s+0}')
  ok=$(grep -hc '^RESULT' "$out"/*.txt 2>/dev/null | awk '{s+=$1} END {print s+0}')

  if [ "$ok" -ne "$nc" ]; then
    echo "    (WARNING: $ok/$nc clients reported; see $out)" >&2
    grep -hiE 'fatal|error' "$out"/*.txt 2>/dev/null | head -3 >&2
  else
    rm -rf "$out"
  fi
  echo "$total"
}

sweep() {
  echo
  echo "qps/client=$QPS depth=$DEPTH secs=$SECS"
  echo "server=$SERVER ($SERVER_IP), one memory region, one server process"
  echo
  printf "%-6s %-8s %-8s %-8s %-8s %-8s\n" "op" "stride" "1 mach" "2 mach" "4 mach" "8 mach"
  printf "%-6s %-8s %-8s %-8s %-8s %-8s\n" "----" "------" "------" "------" "------" "------"
  for op in faa read; do
    for stride in 0 64; do
      local label; [ "$stride" = 0 ] && label="shared" || label="own-line"
      printf "%-6s %-8s " "$op" "$label"
      for nc in 1 2 4 8; do
        printf "%-8s " "$(one "$op" "$nc" "$stride")"
      done
      echo
    done
  done
  echo
  echo "Units are aggregate Mops/s summed across client machines."
  echo "If 'shared' stays flat while 'own-line' scales, the single word is a"
  echo "serialisation point and the flat value is the cluster-wide ceiling."
}

case "${1:-sweep}" in
  build) build ;;
  one)   build; one "${2:-faa}" "${3:-1}" "${4:-0}" ;;
  sweep) build; sweep ;;
  *) echo "usage: $0 [sweep|build|one <faa|read> <n_machines> <stride>]"; exit 2 ;;
esac
