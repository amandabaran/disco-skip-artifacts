#!/bin/bash
export LD_LIBRARY_PATH="/bin/disco-skip/.deps/gcc/relwithdebinfo/lib:$LD_LIBRARY_PATH"
# Run dLSM: Server on memory node, db_bench on compute nodes.
# Usage: ./experiments/dlsm/run.sh [benchmark] [threads]
# Example: ./experiments/dlsm/run.sh fillrandom 16
trap 'kill $(jobs -p) 2>/dev/null' SIGINT
set -uo pipefail

# --- Configuration ---------------------------------------------------------
BASE_DIR="/users/adb321/disco-skip-artifacts"
DLSM_DIR="$BASE_DIR/bin/dlsm"
GATEWAY_LOG_DIR="$(dirname "$(realpath "$0")")/../../logs/dlsm"

# Cluster layout
# Overridable; see the note in run_ycsb.sh about matching resources.
MEM_NODES=(${MEM_NODES:-1})
COMPUTE_NODES=(${COMPUTE_NODES:-2 3 4 5 6})

# db_bench params (override via CLI args or env vars)
BENCHMARK="${1:-fillrandom,readrandom}"
THREADS="${2:-16}"
VALUE_SIZE="${VALUE_SIZE:-400}"
NUM_KEYS="${NUM_KEYS:-20000000}"      # 100M paper total / 5 compute nodes
BLOOM_BITS="${BLOOM_BITS:-10}"
RWPCT="${RWPCT:-5}"
DLSM_PORT="${DLSM_PORT:-19843}"
MEM_SIZE_GB="${MEM_SIZE_GB:-64}"      # per Server arg 2

RUN_TAG="$(date +%Y%m%d-%H%M%S)_${BENCHMARK//,/+}_t${THREADS}"
mkdir -p "$GATEWAY_LOG_DIR"

echo "============================="
echo "dLSM run: $RUN_TAG"
echo "  memory nodes:  ${MEM_NODES[*]/#/w}"
echo "  compute nodes: ${COMPUTE_NODES[*]/#/w}"
echo "  benchmark:     $BENCHMARK"
echo "  threads:       $THREADS"
echo "  keys/node:     $NUM_KEYS"
echo "============================="

# --- Helpers ---------------------------------------------------------------
kill_dlsm() {
  local host=$1
  ssh -n "$host" "pkill -9 -u \$USER -x db_bench 2>/dev/null; \
                  pkill -9 -u \$USER -x Server   2>/dev/null; \
                  fuser -k -9 ${DLSM_PORT}/tcp   2>/dev/null || true"
}

# dLSM's connection.conf: line 1 = compute IPs (space-separated), line 2 = memory IPs
write_connection_conf() {
  local compute_ips memory_ips conf
  compute_ips=$(for n in "${COMPUTE_NODES[@]}"; do
                   getent hosts "w$n" | awk '{print $1; exit}'
                done | paste -sd' ')
  memory_ips=$( for n in "${MEM_NODES[@]}";     do
                   getent hosts "w$n" | awk '{print $1; exit}'
                done | paste -sd' ')
  conf=$(printf "%s\n%s\n" "$compute_ips" "$memory_ips")
  echo "Writing connection.conf:"
  echo "  compute: $compute_ips"
  echo "  memory:  $memory_ips"
  for n in "${COMPUTE_NODES[@]}" "${MEM_NODES[@]}"; do
    # NO -n HERE, and that is the whole point: -n redirects stdin from
    # /dev/null, so `cat` on the far side reads nothing and the here-string is
    # silently discarded. The file gets created, empty, and dLSM then starts
    # with no idea which nodes exist. It wrote a 0-byte connection.conf on
    # every node for as long as this function has existed.
    #
    # -n is used on every OTHER ssh in these scripts, to stop a backgrounded
    # remote command from stealing the loop's stdin. This one needs stdin.
    if ! ssh "w$n" "mkdir -p $DLSM_DIR && cat > $DLSM_DIR/connection.conf" <<< "$conf"; then
      echo "[ERROR] could not write connection.conf on w$n" >&2
      return 1
    fi
    # Verify rather than assume: an empty file here is the failure mode that
    # cost a sweep arm, and it is invisible unless checked.
    local n_bytes
    n_bytes=$(ssh -n "w$n" "stat -c %s $DLSM_DIR/connection.conf 2>/dev/null || echo 0")
    if [ "${n_bytes:-0}" -lt 2 ]; then
      echo "[ERROR] connection.conf on w$n is $n_bytes bytes -- dLSM would start" >&2
      echo "        with no node list. Refusing to continue." >&2
      return 1
    fi
  done
  # EXPLICIT, and not decoration. A bash function returns the status of its LAST
  # executed command, and that is now the size check above -- which is FALSE
  # whenever the file is the right size, so without this the function returned
  # failure exactly when it succeeded. `write_connection_conf || exit 1` then
  # killed the run silently, with no error line, because no echo was reached.
  #
  # Introduced by the verification check itself: before it, the last command was
  # the ssh, which returns 0 on success. Adding a check at the end of a function
  # changes what that function returns.
  return 0
}

# --- 1. Cleanup any prior processes ----------------------------------------
echo "[1/6] Cleanup"
for n in "${COMPUTE_NODES[@]}" "${MEM_NODES[@]}"; do kill_dlsm "w$n"; done
sleep 2

# --- 2. Push connection.conf -----------------------------------------------
echo "[2/6] Distribute connection.conf"
write_connection_conf

# --- 3. Start Server on each memory node -----------------------------------
echo "[3/6] Start Server on memory nodes"
for i in "${!MEM_NODES[@]}"; do
  m="${MEM_NODES[$i]}"
  node_id=$i     # dLSM memory nodes numbered from 0
  ssh -n "w$m" "cd $DLSM_DIR && \
                nohup ./Server $DLSM_PORT $MEM_SIZE_GB $node_id \
                > $DLSM_DIR/server.log 2>&1 &"
  echo "  w$m: ./Server $DLSM_PORT $MEM_SIZE_GB $node_id"
done

# --- 4. Wait for Server to accept connections ------------------------------
echo "[4/6] Wait for Server readiness"
ready=0
for i in {1..30}; do
  if ssh -n "w${MEM_NODES[0]}" "nc -z 127.0.0.1 $DLSM_PORT" >/dev/null 2>&1; then
    ready=1; echo "  Server listening on $DLSM_PORT."; break
  fi
  sleep 1
done
if [ $ready -eq 0 ]; then
  echo "[ERROR] Server didn't come up in 30s. Log tail:"
  ssh -n "w${MEM_NODES[0]}" "tail -50 $DLSM_DIR/server.log"
  for m in "${MEM_NODES[@]}"; do kill_dlsm "w$m"; done
  exit 1
fi

# --- 5. Launch db_bench on each compute node -------------------------------
echo "[5/6] Launch db_bench on compute nodes"
for i in "${!COMPUTE_NODES[@]}"; do
  n="${COMPUTE_NODES[$i]}"
  cn_id=$i      # compute_node_id starts at 0
  log="db_bench_${RUN_TAG}_w${n}.log"
  ssh -n "w$n" "cd $DLSM_DIR && \
                nohup numactl --interleave=all \
                ./db_bench --benchmarks=$BENCHMARK \
                           --threads=$THREADS \
                           --value_size=$VALUE_SIZE \
                           --num=$NUM_KEYS \
                           --bloom_bits=$BLOOM_BITS \
                           --readwritepercent=$RWPCT \
                           --compute_node_id=$cn_id \
                           --fixed_compute_shards_num=0 \
                > $DLSM_DIR/$log 2>&1 &"
  echo "  w$n: db_bench compute_node_id=$cn_id → $log"
  sleep 1
done

# --- 6. Wait for db_bench, tear down, fetch logs ---------------------------
echo "[6/6] Wait for compute nodes to finish"
for n in "${COMPUTE_NODES[@]}"; do
  while ssh -n "w$n" "pgrep -x db_bench >/dev/null 2>&1"; do sleep 5; done
  echo "  w$n done."
done

echo "Tear down Server(s)"
for m in "${MEM_NODES[@]}"; do kill_dlsm "w$m"; done

echo "Fetching logs to $GATEWAY_LOG_DIR"
for n in "${COMPUTE_NODES[@]}"; do
  log="db_bench_${RUN_TAG}_w${n}.log"
  scp -q "w$n:$DLSM_DIR/$log" "$GATEWAY_LOG_DIR/" || echo "  [warn] scp failed for w$n"
done
for m in "${MEM_NODES[@]}"; do
  scp -q "w$m:$DLSM_DIR/server.log" "$GATEWAY_LOG_DIR/server_${RUN_TAG}_w${m}.log" \
      || echo "  [warn] scp failed for w$m"
done

echo "============================="
echo "Done. Logs in $GATEWAY_LOG_DIR"
echo "============================="