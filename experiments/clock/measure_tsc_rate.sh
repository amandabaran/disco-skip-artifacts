#!/usr/bin/env bash
# Measure relative TSC frequency across the cluster.
#
#   ./measure_tsc_rate.sh [window_seconds] [windows] [host...]
#
# Defaults to 30 s x 3 windows over w1..w12. All hosts are measured
# concurrently, which matters: the nodes then share the same wall-clock
# interval and the same thermal conditions, so the frequency differences the
# summary reports are not confounded by having been taken at different times.
#
# Results land in results/<timestamp>/<host>.txt; summarize.py turns them into
# the table.
set -uo pipefail

WINDOW=${1:-30}
REPS=${2:-3}
shift $(( $# > 2 ? 2 : $# ))
HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then
  HOSTS=(w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12)
fi

HERE=$(cd "$(dirname "$0")" && pwd)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HERE/results/$STAMP"
mkdir -p "$OUT"

SSH=(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)

echo "window=${WINDOW}s reps=$REPS hosts=${#HOSTS[@]} -> results/$STAMP"

# Record the clock-relevant facts alongside the numbers. A TSC rate is only
# meaningful if the TSC is invariant, and the ptp4l state decides whether the
# offsets (as opposed to the rates) mean anything at all.
for h in "${HOSTS[@]}"; do
  "${SSH[@]}" "$h" '
    printf "tsc_flags: "; grep -o "constant_tsc\|nonstop_tsc\|tsc_reliable\|rdtscp" /proc/cpuinfo | sort -u | tr "\n" " "; echo
    printf "clocksource: "; cat /sys/devices/system/clocksource/clocksource0/current_clocksource
    printf "model: "; grep -m1 "model name" /proc/cpuinfo | cut -d: -f2- | sed "s/^ //"
    printf "ptp_devices: "; ls /dev/ptp* 2>/dev/null | tr "\n" " "; echo
    printf "ptp4l: "; pgrep -x ptp4l >/dev/null && echo running || echo "not running"
    printf "ntp_sync: "; timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown
  ' > "$OUT/$h.env" 2>/dev/null &
done
wait

# Build once per host, then run every host concurrently.
for h in "${HOSTS[@]}"; do
  scp -q -o StrictHostKeyChecking=no -o BatchMode=yes \
      "$HERE/tsc_rate.c" "$h:/tmp/tsc_rate.c" \
    && "${SSH[@]}" "$h" 'gcc -O2 -o /tmp/tsc_rate /tmp/tsc_rate.c' \
    || echo "$h: build failed" >&2
done

echo "running ${WINDOW}s x ${REPS} concurrently on all hosts (~$(( WINDOW * REPS ))s)"
for h in "${HOSTS[@]}"; do
  "${SSH[@]}" "$h" "/tmp/tsc_rate $WINDOW $REPS" > "$OUT/$h.txt" 2>/dev/null &
done
wait

echo "done -> $OUT"
python3 "$HERE/summarize.py" "$OUT"
