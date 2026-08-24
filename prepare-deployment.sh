#!/bin/bash
set -e

BASE_DIR="$( realpath -sm  "$( dirname "${BASH_SOURCE[0]}" )")"
cd "$BASE_DIR"

rm -rf deployment.zip
echo "Zipping workloads, scripts, and experiments..."
zip -r deployment.zip workloads/ scripts/ experiments/
zip deployment.zip logs/placeholder.txt

# CRITICAL: Include the compiled dependencies/libraries
echo "Zipping dependencies..."
zip -r deployment.zip bin/disco-skip/.deps/

if [ ! -f ycsb-0.12.0.tar.gz ]; then
  echo "YCSB tarball missing; fetching..."
  ./download-ycsb.sh
fi

echo "Zipping binaries and YCSB..."
zip -0 deployment.zip bin/bin.zip
zip -0 deployment.zip ycsb-0.12.0.tar.gz

echo "Deployment package ready."
