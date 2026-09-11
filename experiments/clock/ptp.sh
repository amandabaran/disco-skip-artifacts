#!/usr/bin/env bash
# Discipline the cluster clocks with PTP, and measure the epsilon it achieves.
#
#   ./ptp.sh status     what is disciplining the clocks now
#   ./ptp.sh start      master anchors the domain to UTC, slaves follow by PTP
#   ./ptp.sh measure    report each slave's offset from the master
#   ./ptp.sh roles      check that exactly one node is grandmaster
#   ./ptp.sh stop       kill ptp4l/phc2sys and put chrony back
#
# WHY. Clock mode's timestamps are comparable across machines only to within
# epsilon, and epsilon has to be measured rather than quoted. With chrony the
# nodes sit 172-342 us from a common NTP reference, i.e. ~170 us pairwise,
# against ~2 us operations -- bounded, unlike a one-shot TSC reset, but far too
# coarse for A10. PTP with hardware timestamping is what closes that.
#
# WHICH INTERFACE. enp8s0d1, the 10.10.1.x experiment LAN, whose PHC is ptp2 and
# which reports hardware-transmit and hardware-receive. NOT eno1: that is
# CloudLab's shared control network, where the path is neither ours nor quiet.
#
# ── TOPOLOGY ─────────────────────────────────────────────────────────────────
#
# One free-running oscillator, seeded once to UTC, and everybody follows it.
#
# Master (w1):  chrony steps CLOCK_REALTIME to UTC, then is STOPPED
#               phc_ctl seeds the PHC from CLOCK_REALTIME, once
#               ptp4l serves that PHC to the domain; nothing ever steers it
# Every node:   phc2sys pulls its own PHC -> CLOCK_REALTIME   (identical on w1)
# Slaves:       ptp4l -s slaves the PHC to the master's PHC
#
# So the ONLY asymmetry is `-s` on the slaves plus the one-shot seed on w1.
# Even w1 reads its system clock through its own PHC, so no node is special in
# the way that matters to the application.
#
# WHY THE MASTER IS NOT HELD ON UTC. Keeping chrony running on the master and
# having phc2sys push CLOCK_REALTIME -> PHC puts the NTP servo's corrections
# (172-342 us, measured) into the reference the whole domain follows. Seeding
# once and free-running removes that by construction, and the domain only needs
# UTC to within seconds for logs to make sense. It drifts at w1's natural
# frequency error -- order 20 ppm, ~70 ms/hour -- and `stop` steps that away.
#
# ── THE +-15 US EXCURSIONS, AND WHAT THEY ARE NOT ───────────────────────────
#
# At 1 Sync/s every node showed isolated pairs like this, recurring every
# 16-32 s, on top of a 30 ns median:
#
#   ptp4l[522770.365]: off=+14616 freq=+205881 delay=1153
#   ptp4l[522771.365]: off=-14601 freq=+180977 delay=1153
#   ptp4l[522772.365]: off= -4417 freq=+186829 delay=1151    then rings down
#
# NOT CHRONY. That was the first diagnosis here and it was wrong: w2 and w9
# spiked in the same second once, which looked like a common master-side
# disturbance, but with chrony stopped and the master free-running the pairs
# continued -- and at different times per node (w2 at 770/802/834, w7 at
# 841/856). One coincidence was over-read.
#
# NOT CONGESTION EITHER: `delay` holds flat at ~1150 ns straight through.
#
# What they are: ONE mis-timestamped Sync, given full servo authority. The pair
# is equal and opposite because the servo acts on the bad sample and the next
# reading sees what it did. And the phase error is REAL, not just a bad
# measurement -- the freq column moves +14.6 ppm for one second, which is
# exactly 14.6 us of phase. So epsilon genuinely included these.
#
# THE FIX IS SAMPLE RATE. At 1 Hz a single outlier owns the whole correction.
# At 8 Hz (logSyncInterval -3) it gets an eighth of the authority and the
# residue is gone in about a second, so the servo averages the outlier away
# instead of chasing it. phc2sys is raised to match with -R 8; leaving it at 1 Hz
# would just move the bottleneck to the second hop, which is the hop the
# application actually reads.
#
# REVERTIBLE ON PURPOSE. `start` stops chrony on the slaves; `stop` restores it
# everywhere. Leaving a cluster with no clock discipline is worse than leaving
# it on NTP, so stop is the safe state to return to.
#
# DNS IS BROKEN ON THIS CLUSTER (every node but w5 fails to resolve anything),
# and chrony's stock config lists only hostnames -- so after a chronyd restart
# it has ZERO usable sources and cannot step at all. `stop` therefore pins the
# emulab NTP server by IP before restarting chrony. 128.110.100.34 is
# ops.apt.emulab.net, 0.6 ms away, and is what w5 selects when DNS works.
set -uo pipefail

MASTER=w1
SLAVES=(w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12)
ALL=("$MASTER" "${SLAVES[@]}")
IFACE=enp8s0d1
NTP_IP=128.110.100.34
# log2 seconds between Sync messages. 0 = 1 Hz, -3 = 8 Hz.
#
# KEEP THIS AT 0 UNLESS YOU ALSO CHECK THE LOG FORMAT. Below 1 s ptp4l stops
# printing a per-sample `master offset` line and prints a per-second
# `rms N max N freq ...` summary instead. Both are parsed below now, but the
# per-sample form is what a distribution can be built from, and 1 Hz measured
# BETTER anyway: medians of ~30 ns against ~800 ns at 8 Hz, because phc2sys is
# then chasing a PHC that the faster servo jerks more often.
SYNC_INTERVAL=${PTP_SYNC_INTERVAL:-0}
# pi (default) or linreg. The recurring excursion below is one bad sample given
# full servo authority, so a regression servo -- which fits a window and is
# inherently robust to a single outlier -- is the targeted lever. Compare arms
# with: PTP_SERVO=linreg ./ptp.sh start
SERVO=${PTP_SERVO:-pi}
SSH=(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes)

status() {
  for h in "${ALL[@]}"; do
    printf "%-4s " "$h"
    "${SSH[@]}" "$h" '
      p=$(pgrep -x ptp4l >/dev/null && echo ptp4l || echo -)
      c=$(pgrep -x chronyd >/dev/null && echo chronyd || echo -)
      s=$(pgrep -x phc2sys >/dev/null && echo phc2sys || echo -)
      echo "ptp4l=$p phc2sys=$s chronyd=$c"' 2>/dev/null || echo "unreachable"
  done
}

# Which nodes think they are master. Exactly one should, and it should be
# $MASTER. Checking this is not optional: the whole first run was invalidated by
# a split domain that every other output looked fine under.
roles() {
  local masters=""
  for h in "${ALL[@]}"; do
    printf "%-4s " "$h"
    local st
    st=$("${SSH[@]}" "$h" "
      # Last port state transition wins; grandmaster claims count as MASTER.
      tail -200 /tmp/ptp4l.log 2>/dev/null \
        | grep -oE 'to (MASTER|SLAVE|LISTENING|UNCALIBRATED)|assuming the grand master role' \
        | tail -1" 2>/dev/null)
    # Below a 1 s sync interval ptp4l prints `rms N max N freq ...` summaries
    # instead of per-sample `master offset` lines. Counting only the latter
    # declared all 12 nodes master at 8 Hz -- the same silent-blindness bug as
    # the empty w1 phc2sys column. Match both.
    local off
    off=$("${SSH[@]}" "$h" "grep -cE 'master offset|^ptp4l.*rms ' /tmp/ptp4l.log 2>/dev/null" 2>/dev/null)
    if [ "${off:-0}" -gt 0 ]; then
      echo "SLAVE   (${off} offset samples)"
    else
      echo "MASTER? (${st:-no log}) -- no master offset samples"
      masters="$masters $h"
    fi
  done
  echo
  if [ "$(echo $masters | wc -w)" -eq 1 ] && [ "$(echo $masters | tr -d ' ')" = "$MASTER" ]; then
    echo "OK: exactly one master, and it is $MASTER"
  else
    echo "BAD: master set is '$masters', expected exactly '$MASTER'"
  fi
}

start() {
  echo "master=$MASTER seeds the domain from UTC once, then free-runs"

  # ── Master: get CLOCK_REALTIME onto UTC, then take chrony away ─────────────
  # chrony is used exactly once, to step, and then stopped -- see TOPOLOGY for
  # why leaving it running is worse. DNS is broken here, hence the pinned IP.
  "${SSH[@]}" "$MASTER" "
    echo 'server $NTP_IP iburst prefer' | sudo tee /etc/chrony/sources.d/emulab-ip.sources >/dev/null
    sudo systemctl start chrony 2>/dev/null || sudo systemctl start chronyd 2>/dev/null
    sudo chronyc reload sources >/dev/null 2>&1" >/dev/null 2>&1
  echo "  waiting for chrony on $MASTER to select a source and step"
  for _ in $(seq 1 20); do
    sleep 2
    "${SSH[@]}" "$MASTER" 'sudo chronyc makestep >/dev/null 2>&1' >/dev/null 2>&1
    local refid
    refid=$("${SSH[@]}" "$MASTER" "sudo chronyc tracking 2>/dev/null | awk '/Reference ID/{print \$4}'" 2>/dev/null)
    [ -n "$refid" ] && [ "$refid" != "00000000" ] && break
  done
  local track
  track=$("${SSH[@]}" "$MASTER" "sudo chronyc tracking 2>/dev/null | awk -F': *' '/Last offset|Reference ID/{print \$2}' | tr '\n' ' '" 2>/dev/null)
  echo "  $MASTER tracking: ${track:-UNKNOWN}"
  case "$track" in
    ""|00000000*) echo "  REFUSING TO START: $MASTER has no NTP source, so the"
                  echo "  domain would be seeded from an arbitrary clock."
                  return 1 ;;
  esac

  "${SSH[@]}" "$MASTER" "
    sudo systemctl stop chrony chronyd systemd-timesyncd 2>/dev/null
    sudo pkill -x ptp4l; sudo pkill -x phc2sys; sleep 0.3
    # Seed the PHC from the freshly-stepped CLOCK_REALTIME, once. From here on
    # this oscillator IS the domain's definition of time.
    sudo phc_ctl $IFACE set >/dev/null 2>&1
    sudo nohup ptp4l -H -i $IFACE -m --priority1 64 \
      --logSyncInterval $SYNC_INTERVAL --logMinDelayReqInterval $SYNC_INTERVAL \
      --clock_servo $SERVO > /tmp/ptp4l.log 2>&1 &
    sleep 0.5
    sudo nohup phc2sys -s $IFACE -c CLOCK_REALTIME -O 0 -S 1 -R 8 -m > /tmp/phc2sys.log 2>&1 &
    true" >/dev/null 2>&1
  sleep 3

  # ── Slaves: client-only, so none of them can win an election ──────────────
  for h in "${SLAVES[@]}"; do
    "${SSH[@]}" "$h" "
      sudo systemctl stop chrony chronyd systemd-timesyncd 2>/dev/null
      sudo pkill -x ptp4l; sudo pkill -x phc2sys; sleep 0.3
      sudo nohup ptp4l -H -i $IFACE -m -s \
        --logMinDelayReqInterval $SYNC_INTERVAL --clock_servo $SERVO \
        > /tmp/ptp4l.log 2>&1 &
      sleep 0.5
      sudo nohup phc2sys -s $IFACE -c CLOCK_REALTIME -O 0 -S 1 -R 8 -m > /tmp/phc2sys.log 2>&1 &
      true" >/dev/null 2>&1 &
  done
  wait
  echo "started (sync=2^$SYNC_INTERVAL s, servo=$SERVO); allow ~90s to converge, then: ./ptp.sh roles && ./ptp.sh measure"
}

# Report the two hops separately and then bound epsilon by their sum. Both are
# hardware-assisted measurements, but they are the daemons' own, so they are a
# bound on what a thread sees rather than a direct observation of it.
# Pull the raw offset samples off every node into $1/<host>.<which>, so the
# statistics are computed in ONE place on ONE implementation. Escaping awk
# through two levels of ssh quoting was how the earlier version of this
# function grew a syntax error that produced empty columns rather than failing.
collect() {
  local dir=$1 n=$2
  mkdir -p "$dir"
  for h in "${ALL[@]}"; do
    ( # Per-sample `master offset` lines at 1 Hz; per-second `rms R max M`
      # summaries below that. From a summary only the max is recoverable.
      "${SSH[@]}" "$h" "
        if grep -q 'master offset' /tmp/ptp4l.log 2>/dev/null; then
          echo SAMPLES
          grep -oE 'master offset +-?[0-9]+' /tmp/ptp4l.log | grep -oE '\-?[0-9]+$'
        else
          echo MAXIMA
          grep -oE ' max +[0-9]+' /tmp/ptp4l.log 2>/dev/null | grep -oE '[0-9]+$'
        fi" 2>/dev/null | tail -$((n+1)) > "$dir/$h.ptp"
      "${SSH[@]}" "$h" "grep -oE '(phc|sys) offset +-?[0-9]+' /tmp/phc2sys.log 2>/dev/null \
        | grep -oE '\-?[0-9]+$'" 2>/dev/null | tail -$n > "$dir/$h.phc"
    ) &
  done
  wait
}

measure() {
  local n=${1:-600}
  local dir
  dir=$(mktemp -d)
  collect "$dir" "$n"
  MASTER="$MASTER" python3 - "$dir" "$n" <<'PYEOF'
import os, sys, glob

d, n = sys.argv[1], int(sys.argv[2])
master = os.environ.get("MASTER", "w1")

def read(path):
    try:
        raw = open(path).read().split()
    except OSError:
        return [], ""
    kind = ""
    if raw and raw[0] in ("SAMPLES", "MAXIMA"):
        kind, raw = raw[0], raw[1:]
    return [abs(int(x)) for x in raw if x.lstrip("-").isdigit()], kind

def pct(v, q):
    if not v:
        return None
    s = sorted(v)
    i = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return s[i]

def cell(v):
    if not v:
        return f"{'-':>7}{'-':>8}{'-':>8}{'-':>8}{'-':>7}{0:>6}"
    over = 100.0 * sum(1 for x in v if x > 1000) / len(v)
    # n is printed because p99 == max is the tell-tale of too short a window,
    # and a window short enough to still contain the servo's convergence
    # transient reads as a bad clock. It misled a whole comparison once.
    return (f"{pct(v,.5):>7}{pct(v,.9):>8}{pct(v,.99):>8}"
            f"{max(v):>8}{over:>6.1f}%{len(v):>6}")

print(f"PTP epsilon, last {n} samples per node. All figures ns, |signed|.\n")
print("  ptp_*  slave PHC vs master PHC      (ptp4l)")
print("  phc_*  CLOCK_REALTIME vs own PHC    (phc2sys) -- the hop the app reads")
print("  >1us   percent of samples over 1000 ns\n")
hdr = f"{'p50':>7}{'p90':>8}{'p99':>8}{'max':>8}{'>1us':>7}{'n':>6}"
print(f"{'node':<5} | {hdr} | {hdr}")
print(f"{'-'*5}-+-{'-'*44}-+-{'-'*44}")

hosts = sorted(glob.glob(f"{d}/*.ptp"),
               key=lambda p: int("".join(c for c in os.path.basename(p)[1:].split(".")[0] if c.isdigit())))
worst_sum, worst_host, summarised, counts = 0, None, [], []
for path in hosts:
    h = os.path.basename(path)[:-4]
    ptp, kind = read(path)
    phc, _ = read(f"{d}/{h}.phc")
    if kind == "MAXIMA" and ptp:
        summarised.append(h)
    if h != master:
        counts.append((h, len(ptp)))
    print(f"{h:<5} | {cell(ptp)} | {cell(phc)}")
    # Triangle inequality on the two hops, worst sample of each. The master has
    # no ptp4l hop by definition -- it IS the reference.
    s = (max(ptp) if ptp else 0) + (max(phc) if phc else 0)
    if s > worst_sum:
        worst_sum, worst_host = s, h

print()
# CONVERGENCE IS NOT EPSILON. ptp4l needs ~60-90 s to pull in, and `start`
# itself spends minutes in the chrony wait loop BEFORE the daemons launch --
# so "a few minutes after start" can still be 70 s of daemon uptime. Measuring
# there reads the servo's pull-in as a bad clock. It invalidated a whole
# 1 Hz-vs-8 Hz and pi-vs-linreg comparison before this check existed.
short = [h for h, c in counts if 0 < c < 240]
if short:
    print(f"*** WINDOW TOO SHORT on {', '.join(short)}: fewer than 240 ptp4l")
    print("*** samples, so this still contains the servo's convergence")
    print("*** transient and OVERSTATES epsilon. Let it run and re-measure;")
    print("*** `ps -o etimes= -C ptp4l` on a node is the real uptime.")
    print()
if summarised:
    print(f"NOTE: {', '.join(summarised)} logged per-second summaries, not per-sample")
    print("      offsets, so only the max was recoverable and their p50/p90/p99")
    print("      columns OVERSTATE the typical case. Run at SYNC_INTERVAL=0.")
    print()
print("EPSILON. A thread reads CLOCK_REALTIME, so its offset from the master is")
print("at most (its phc2sys error) + (its ptp4l error). Two threads on different")
print("nodes therefore differ by at most twice the worst per-node sum.")
print(f"  worst per-node sum:  {worst_sum} ns  (on {worst_host})")
print(f"  => pairwise epsilon: {2*worst_sum} ns = {2*worst_sum/1000.0:.1f} us")
print()
print("The ptp4l column ALONE understates it: the application never reads the")
print("PHC. And report the distribution, not one number -- these operations take")
print("~2 us, so a p50 of tens of ns and a max of tens of us are different")
print("claims, and it is the max that linearizability depends on.")
PYEOF
  rm -rf "$dir"
}

stop() {
  echo "stopping ptp4l/phc2sys and restoring chrony"
  for h in "${ALL[@]}"; do
    "${SSH[@]}" "$h" "
      sudo pkill -x phc2sys; sudo pkill -x ptp4l
      # Pin the source by IP: DNS is broken here, so a restarted chronyd would
      # otherwise come up with no sources and be unable to step at all.
      echo 'server $NTP_IP iburst prefer' | sudo tee /etc/chrony/sources.d/emulab-ip.sources >/dev/null
      sudo systemctl start chrony 2>/dev/null || sudo systemctl start chronyd 2>/dev/null
      sudo chronyc reload sources >/dev/null 2>&1
      sleep 4; sudo chronyc makestep >/dev/null 2>&1
      true" >/dev/null 2>&1 &
  done
  wait
  echo "restored; verify with: ./ptp.sh skew"
}

# Absolute sanity check, independent of any daemon's self-report: ask every node
# for the wall clock at what is nominally the same instant. Resolution is only
# ~ms because ssh fan-out dominates, so this catches SECONDS-scale breakage --
# the 62 s excursion above -- and nothing finer. It is not an epsilon measurement.
skew() {
  echo "date -u on every node (ms resolution at best; ssh jitter dominates)"
  for h in "${ALL[@]}"; do
    ( printf "%-5s %s\n" "$h" \
        "$("${SSH[@]}" "$h" 'date -u +%H:%M:%S.%3N' 2>/dev/null || echo unreachable)" ) &
  done
  wait
  printf "%-5s %s\n" toad "$(date -u +%H:%M:%S.%3N)"
}

case "${1:-status}" in
  status)  status ;;
  start)   start ;;
  measure) measure "${2:-20}" ;;
  roles)   roles ;;
  skew)    skew ;;
  stop)    stop ;;
  *) echo "usage: $0 {status|start|measure [n]|roles|skew|stop}"; exit 2 ;;
esac
