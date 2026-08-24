#!/bin/bash
set -e

BASE_DIR="$( realpath -sm  "$( dirname "${BASH_SOURCE[0]}" )")"
cd "$BASE_DIR"

source "$BASE_DIR/scripts/config.sh"

deploy_to_node() {
  local idx=$1
  local node="w${idx}"

  (
    ssh "$node" "mkdir -p \"$BASE_DIR\""
    scp -C -o Cipher=chacha20-poly1305@openssh.com deployment.zip "${node}:$BASE_DIR/deployment.zip"

    ssh "$node" "unzip -o \"$BASE_DIR/deployment.zip\" -d \"$BASE_DIR\"; \
             cd \"$BASE_DIR\"; \
             tar -xf ycsb-0.12.0.tar.gz; \
             rm -rf YCSB; mv ycsb-0.12.0 YCSB; \
             cd \"$BASE_DIR/bin\"; \
             mkdir -p staging; \
             unzip -o -q bin.zip -d staging/; \
             mv -f staging/chimera     ./chimera-exe     2>/dev/null || true; \
             mv -f staging/disco-skip  ./disco-skip-exe  2>/dev/null || true; \
             mkdir -p dlsm; \
             if [ -d staging/dlsm/out ]; then \
               mv -f staging/dlsm/out/* ./dlsm/ ; \
             fi; \
             rm -rf staging/dlsm; \
             [ -f ./dlsm/connection.conf ] && mv -f ./dlsm/connection.conf ./connection.conf; \
             mv -f staging/* ./ 2>/dev/null || true; \
             rm -rf staging;"

    echo " ✓ [${node}] Deployment payload successfully processed and verified."
  ) 2>&1 | sed "s/^/[${node}] /"
}

echo "Starting parallel broadcast deployment to ${MACHINE_COUNT} nodes..."
echo "------------------------------------------------------------"

for i in $(seq 1 "$MACHINE_COUNT"); do
  deploy_to_node "$i" &
done

wait

echo "------------------------------------------------------------"
echo "Parallel deployment successful across all nodes!"