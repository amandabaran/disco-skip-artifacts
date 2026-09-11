#!/bin/bash
export LD_LIBRARY_PATH="/bin/disco-skip/.deps/gcc/relwithdebinfo/lib:$LD_LIBRARY_PATH"
# Run dLSM under YCSB workloads via ycsbc.
# Assumes bin/dlsm/connection.conf is already correct on every node.
# Usage: ./experiments/dlsm/run_ycsb.sh [workload] [distribution] [threads]
trap 'kill $(jobs -p) 2>/dev/null' SIGINT
set -uo pipefail

BASE_DIR="/users/adb321/disco-skip-artifacts"
DLSM_DIR="$BASE_DIR/bin/dlsm"
GATEWAY_LOG_DIR="$(dirname "$(realpath "$0")")/../../logs/dlsm"

MEM_NODES=(1)
COMPUTE_NODES=(2 3 4 5 6)

WORKLOAD="${1:-ycsb-c}"          # ycsb-c | insert-only | update-only | scan-only
DISTRIBUTION="${2:-zipfian}"     # zipfian | uniform
THREADS="${3:-4}"
COROUTINES="${COROUTINES:-4}"
DLSM_PORT="${DLSM_PORT:-19843}"
MEM_SIZE_GB="${MEM_SIZE_GB:-64}"
# Upper bound of ycsbc's uniform scan length. 100 is upstream's hardcoded value,
# so leaving this unset reproduces an unmodified dLSM. See bin/dlsm/build.sh.
DLSM_SCAN_LEN_MAX="${DLSM_SCAN_LEN_MAX:-100}"

RUN_TAG="$(date +%Y%m%d-%H%M%S)_${WORKLOAD}_${DISTRIBUTION}_t${THREADS}c${COROUTINES}_s${DLSM_SCAN_LEN_MAX}"
mkdir -p "$GATEWAY_LOG_DIR"

echo "============================="
echo "dLSM/YCSB: $RUN_TAG"
echo "  workload/dist: $WORKLOAD / $DISTRIBUTION"
echo "  threads/coros: $THREADS / $COROUTINES"
echo "  scan len max:  1..$DLSM_SCAN_LEN_MAX"
echo "  memory nodes:  ${MEM_NODES[*]/#/w}"
echo "  compute nodes: ${COMPUTE_NODES[*]/#/w}"
echo "============================="

kill_dlsm() {
  ssh -n "$1" "pkill -9 -u \$USER -x ycsbc  2>/dev/null; \
               pkill -9 -u \$USER -x Server 2>/dev/null; \
               fuser -k -9 ${DLSM_PORT}/tcp 2>/dev/null || true"
}

# 1. Cleanup
echo "[1/5] Cleanup"
for n in "${COMPUTE_NODES[@]}" "${MEM_NODES[@]}"; do kill_dlsm "w$n"; done
sleep 2

# 2. Start Server on memory node(s)
echo "[2/5] Start Server"
for i in "${!MEM_NODES[@]}"; do
  m="${MEM_NODES[$i]}"
  ssh -n "w$m" "cd $DLSM_DIR && nohup ./Server $DLSM_PORT $MEM_SIZE_GB $i \
                > $DLSM_DIR/server.log 2>&1 &"
  echo "  w$m: Server $DLSM_PORT $MEM_SIZE_GB $i"
done

# 3. Wait for readiness
echo "[3/5] Wait for Server on port $DLSM_PORT"
ready=0
for i in {1..30}; do
  if ssh -n "w${MEM_NODES[0]}" "nc -z 127.0.0.1 $DLSM_PORT" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 1
done
if [ $ready -eq 0 ]; then
  echo "[ERROR] Server not listening. Log tail:"
  ssh -n "w${MEM_NODES[0]}" "tail -50 $DLSM_DIR/server.log"
  for m in "${MEM_NODES[@]}"; do kill_dlsm "w$m"; done
  exit 1
fi

# 4. Launch ycsbc on compute nodes
echo "[4/5] Launch ycsbc"
for n in "${COMPUTE_NODES[@]}"; do
  log="ycsbc_${RUN_TAG}_w${n}.log"
  # DLSM_SCAN_LEN_MAX must be set IN THE REMOTE SHELL. Exporting it on the
  # gateway does nothing -- ssh does not forward arbitrary env by default -- so
  # every arm of a scan-length sweep would silently run at the upstream default
  # of 100 and the sweep would be four copies of one measurement.
  ssh -n "w$n" "cd $DLSM_DIR && DLSM_SCAN_LEN_MAX=$DLSM_SCAN_LEN_MAX \
                nohup numactl --interleave=all \
                ./ycsbc $THREADS $COROUTINES $WORKLOAD $DISTRIBUTION \
                > $DLSM_DIR/$log 2>&1 &"
  echo "  w$n: ycsbc $THREADS $COROUTINES $WORKLOAD $DISTRIBUTION"
done

# 5. Wait, teardown, fetch logs
echo "[5/5] Wait for compute nodes"
for n in "${COMPUTE_NODES[@]}"; do
  while ssh -n "w$n" "pgrep -x ycsbc >/dev/null 2>&1"; do sleep 5; done
  echo "  w$n done"
done

for m in "${MEM_NODES[@]}"; do kill_dlsm "w$m"; done

echo "Fetching logs → $GATEWAY_LOG_DIR"
for n in "${COMPUTE_NODES[@]}"; do
  scp -q "w$n:$DLSM_DIR/ycsbc_${RUN_TAG}_w${n}.log" "$GATEWAY_LOG_DIR/" \
      || echo "  [warn] w$n scp failed"
done
for m in "${MEM_NODES[@]}"; do
  scp -q "w$m:$DLSM_DIR/server.log" "$GATEWAY_LOG_DIR/server_${RUN_TAG}_w${m}.log" || true
done

echo "Done."