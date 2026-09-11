#!/bin/bash
# Build dLSM out-of-tree.
#
# dLSM/ IS KEPT UPSTREAM-UNMODIFIED, WITH ONE DELIBERATE EXCEPTION.
# dLSM/include/util/ycsb.h hardcoded the uniform scan length as 1..100; it now
# reads the bound from $DLSM_SCAN_LEN_MAX and returns 100 when that is unset, so
# the default build is behaviourally identical to upstream. The reason is the
# workload-E comparison: our oops-workloade-* files set maxscanlength, and
# comparing our 1..8 scans against dLSM's 1..100 (mean ~50) is not a
# comparison. The env var lets both sides be swept over the same lengths.
#
# If dLSM is ever re-pulled, that is the one hunk to reapply, and it is saved
# as a patch because dLSM/ is untracked and the edit would otherwise be lost:
#
#     cd "$BASE_DIR/dLSM" && patch -p1 < ../experiments/dlsm/dlsm-scanlen.patch
#
# Anything else in dLSM/ should still be treated as off-limits.
set -euo pipefail

BASE_DIR="$( realpath -sm "$( dirname "${BASH_SOURCE[0]}" )/../.." )"
DLSM_SRC="$BASE_DIR/dLSM"
DLSM_BUILD="$BASE_DIR/bin/dlsm/build"   # was: "$DLSM_SRC/build"
DLSM_OUT="$BASE_DIR/bin/dlsm/out"

usage() {
  echo "usage: $0 [build|clean|distclean|buildclean|tidyclean]" >&2
}

cmd="${1:-build}"
case "$cmd" in
  clean|buildclean|distclean)
    echo "[dlsm] cleaning"
    rm -rf "$DLSM_BUILD" "$DLSM_OUT"
    exit 0
    ;;
  tidyclean)
    exit 0
    ;;
  build)
    ;;
  *)
    usage; exit 2
    ;;
esac

mkdir -p "$DLSM_BUILD" "$DLSM_OUT"

# Exact command from dLSM README, invoked from a script so we don't cd inside dLSM/.
cmake -S "$DLSM_SRC" -B "$DLSM_BUILD" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_EXE_LINKER_FLAGS="-lsnappy" \
      -DCMAKE_SHARED_LINKER_FLAGS="-lsnappy"

cmake --build "$DLSM_BUILD" -j"$(nproc)" --target Server db_bench TimberSaw ycsbc

# Stage artifacts into a predictable location for the packager.
cp -f "$DLSM_BUILD/Server"   "$DLSM_OUT/"
cp -f "$DLSM_BUILD/db_bench" "$DLSM_OUT/"
cp -f "$DLSM_BUILD/ycsbc"    "$DLSM_OUT/"
shopt -s nullglob
for f in "$DLSM_BUILD"/libTimberSaw.*; do
  cp -f "$f" "$DLSM_OUT/"
done

if [ -f "$DLSM_SRC/connection.conf" ]; then
  cp -f "$DLSM_SRC/connection.conf" "$DLSM_OUT/"
else
  echo "[dlsm] WARNING: dLSM/connection.conf missing on gateway — nodes won't get one" >&2
fi

echo "[dlsm] staged artifacts:"
ls -1 "$DLSM_OUT"