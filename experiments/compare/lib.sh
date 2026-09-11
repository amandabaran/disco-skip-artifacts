#!/bin/bash
# Shared plumbing for the comparison sweeps.
#
# THE ONE THING THIS FILE EXISTS FOR: the three systems do not report
# throughput the same way, and comparing their printed numbers directly is
# wrong by a factor of the client count.
#
#   disco-skip  "Local tput: {} kops"        iter_count*1e6/elapsed   PER CLIENT
#   swarm-kv    "Local tput: {}kpos"         iter_count*1e6/elapsed   PER CLIENT
#   fusee       "aggregated tput: {}kops"    num_clients*iter/elapsed AGGREGATE
#
# (The `kpos` is swarm-kv's own typo, and it is load-bearing here -- a pattern
# matching `kops` silently finds nothing in a swarm-kv log and the arm reports
# FAILED rather than wrong, which is the better failure but still a failure.)
#
# So every number is normalised to ONE definition: sum of per-client
# throughputs. fusee's aggregate is divided by the client count to recover its
# per-client rate first, which is exact given the formula above. Anything else
# compares a single client against a cluster.
#
# Logs live on the machine that ran the client: client c runs on
# w$((FIRST_CLIENT + (c-1) % CLIENT_MACHINES)), so gathering is per-client ssh.

SCRIPT_DIR_LIB="$( realpath -sm "$( dirname "${BASH_SOURCE[0]}" )"/../../scripts )"
source "$SCRIPT_DIR_LIB"/config.sh

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)

# Which worker ran client $1 (1-based), given $2 clients.
client_host() {
  local c=$1
  local idx=$(( FIRST_CLIENT + (c - 1) % CLIENT_MACHINES ))
  local var="machine$idx"
  echo "${!var}"
}

# Pull every client log for a run into $3/, named client<N>.txt.
# Usage: fetch_logs <folder> <nclients> <destdir>
fetch_logs() {
  local folder=$1 nclients=$2 dest=$3
  mkdir -p "$dest"
  local c
  for c in $(seq 1 "$nclients"); do
    local h; h=$(client_host "$c")
    ssh "${SSH_OPTS[@]}" "$h" "cat $ROOT_DIR/logs/$folder/client$c.txt" \
        > "$dest/client$c.txt" 2>/dev/null &
  done
  wait
}

# Sum of per-client kops across the fetched logs.
# Usage: total_kops <system> <nclients> <logdir>
# Prints: "<total> <n_parsed> <per-client csv>"
total_kops() {
  local system=$1 nclients=$2 dir=$3
  local total=0 parsed=0 percsv=""
  local c v
  for c in $(seq 1 "$nclients"); do
    local f="$dir/client$c.txt"
    [ -s "$f" ] || continue
    case "$system" in
      disco-skip|disco-skip-exe)
        v=$(grep -oE 'Local tput: [0-9]+ kops' "$f" | grep -oE '[0-9]+' | tail -1) ;;
      swarmkv)
        v=$(grep -oE 'Local tput: [0-9]+kpos' "$f" | grep -oE '[0-9]+' | tail -1) ;;
      fusee)
        # Aggregate -> per client. Integer division loses <1 kops per client,
        # which is under the run-to-run noise and is not worth a float here.
        local agg
        agg=$(grep -oE 'aggregated tput: [0-9]+kops' "$f" | grep -oE '[0-9]+' | tail -1)
        v=""
        [ -n "$agg" ] && v=$(( agg / nclients )) ;;
      *) v="" ;;
    esac
    if [ -n "$v" ]; then
      total=$(( total + v )); parsed=$(( parsed + 1 ))
      percsv="${percsv}${percsv:+,}${v}"
    fi
  done
  echo "$total $parsed $percsv"
}

# Did any client hit a condition that voids the number?
# Arena exhaustion is the one that matters: with no reclamation, a run that
# outlives its stripe stops doing work and the tput is meaningless.
run_warnings() {
  local dir=$1 out=""
  grep -qil "exhaust" "$dir"/client*.txt 2>/dev/null && out="$out ARENA-EXHAUSTED"
  grep -qiE "terminate|what\(\):|Segmentation|Unrecognized token" "$dir"/client*.txt 2>/dev/null \
      && out="$out CRASH-OR-BAD-ARGS"
  echo "$out"
}
