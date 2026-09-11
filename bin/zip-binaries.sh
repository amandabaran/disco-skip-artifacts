#!/bin/bash
# Package the built binaries into bin/bin.zip for deployment.
#
# send-deployment.sh unzips this into bin/staging/ on every worker and then
# renames the entries it recognises (staging/disco-skip -> ./disco-skip-exe,
# and so on). Those renames use `|| true`, so a binary missing from here fails
# silently: the worker simply has no such executable, the tmux window dies the
# instant run.sh launches it, and wait-till-completion.sh reports
# "can't find window: server1". That is a confusing symptom for a packaging
# problem, which is why this script fails loudly instead.
#
# Paths are discovered rather than hardcoded, because where a conan build leaves
# its executables depends on the profile and build type.
set -euo pipefail

SCRIPT_DIR="$( realpath -sm "$( dirname "${BASH_SOURCE[0]}" )")"
cd "$SCRIPT_DIR"

# Each entry is "<label>:<checkout dir>:<executable name>". A checkout that is
# not present is skipped, so this works whether or not the older projects are
# still deployed alongside.
#
# ALL THREE LIVE IN disco-skip. The disco-skip repo is a copy of chimera with
# chimera itself removed, so swarm-kv/ and fusee/ are siblings of disco-skip/
# inside it and build from the same conan stack (see targets.yaml). These
# entries used to name a `chimera` checkout, which does not exist under bin/ --
# so both comparison binaries were silently skipped on every repack, the
# `mv -f staging/fusee` in send-deployment.sh failed with its `|| true`, and the
# workers kept running whatever copy was last deployed. They were 2 days stale
# before anyone looked.
TARGETS=(
  "disco-skip:disco-skip:disco-skip"
  "swarm-kv:disco-skip:swarmkv"
  "fusee:disco-skip:fusee"
)

# Only disco-skip is required. The rest are historical comparison binaries and
# their absence is not an error.
REQUIRED=("disco-skip")

found_paths=()
found_labels=()

find_executable() {
  local checkout=$1 exe=$2 best="" cand
  [ -d "$checkout" ] || return 1
  # Newest wins, so a fresh rebuild beats a stale copy left in a sibling build
  # tree. Done with a loop and -nt rather than `find -printf`, which is
  # GNU-only and would make this untestable anywhere but the cluster.
  while IFS= read -r cand; do
    if [ -z "$best" ] || [ "$cand" -nt "$best" ]; then best="$cand"; fi
  done < <(find "$checkout" -type f -name "$exe" -perm -u+x 2>/dev/null)
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

for entry in "${TARGETS[@]}"; do
  IFS=: read -r label checkout exe <<<"$entry"
  path=$(find_executable "$checkout" "$exe" || true)
  if [ -n "$path" ]; then
    found_paths+=("$path")
    found_labels+=("$label")
    echo "  found $label -> $path"
  else
    echo "  (no $label binary under ./$checkout)"
  fi
done

have_label() {
  local want=$1 l
  # Guarded against an empty array, which `set -u` treats as an unbound
  # variable on older bash.
  [ ${#found_labels[@]} -eq 0 ] && return 1
  for l in "${found_labels[@]}"; do
    [ "$l" = "$want" ] && return 0
  done
  return 1
}

for req in "${REQUIRED[@]}"; do
  if ! have_label "$req"; then
    echo >&2
    echo >&2 "ERROR: no '$req' executable found under $SCRIPT_DIR."
    echo >&2 "Build it first, from the checkout root:"
    echo >&2 "    ./build.py disco-skip"
    echo >&2 "Packaging without it would deploy silently-missing binaries and"
    echo >&2 "surface later as 'can't find window: server1'."
    exit 1
  fi
done

rm -f bin.zip
# -D: no directory entries, -j: junk paths, so names land flat in staging/.
zip -Dj bin.zip "${found_paths[@]}"

# dLSM goes in WITH its path, deliberately. send-deployment.sh already has a
# branch that moves staging/dlsm/out/* into bin/dlsm/, and it was dead code:
# the -j above junks every path, so nothing ever created staging/dlsm/out and
# the branch never fired. The consequence was that dLSM had no automated deploy
# path at all -- the binaries on the workers were hand-copied and went stale
# (Sep 9 against a Sep 11 rebuild), so a dLSM measurement silently ran the wrong
# build. Adding them here is what makes that branch do its job.
#
# Not REQUIRED: dLSM is an independent CMake build (bin/dlsm/build.sh) and a
# checkout without it should still package the RDMA binaries.
DLSM_BINS=()
for b in dlsm/out/Server dlsm/out/ycsbc dlsm/out/db_bench; do
  [ -f "$b" ] && DLSM_BINS+=("$b")
done
if [ "${#DLSM_BINS[@]}" -gt 0 ]; then
  zip -q bin.zip "${DLSM_BINS[@]}"
  echo "  found dlsm -> ${DLSM_BINS[*]}"
else
  echo "  (no dlsm binaries under ./dlsm/out -- run bin/dlsm/build.sh build)"
fi

echo "Success: bin/bin.zip created with: ${found_labels[*]}${DLSM_BINS:+ dlsm}"
