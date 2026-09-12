# Comparison sweeps: disco-skip vs fusee, swarm-kv, dLSM

Two scripts, because the comparison splits on whether the workload needs an
ordered scan.

```sh
./ycsb-abcd.sh [iter] [warmup]     # A B C D : disco-skip vs swarm-kv vs fusee
./ycsb-e.sh    [iter] [warmup]     # E       : disco-skip vs dLSM, swept on scan length
```

`SERVERS`, `CLIENTS`, `VECS`, `NODES` are environment overrides; `SCANLENS`
overrides the E sweep (default `8 32 100`).

## Why the split is not arbitrary

**swarm-kv and fusee have no range operation.** Both parse `SCAN` from the YCSB
trace and then emulate it as `scan_count` sequential point reads on incremented
keys (`fusee/src/main.cpp:580`, `swarm-kv/src/main.cpp:502` — swarm-kv even
calls `finishAllFutures()` inside that loop, so it is one round trip per key).
Neither is an ordered structure. Putting an ordered range against that would
flatter us by a large factor and measure nothing about either system, so E goes
to dLSM, which is a real LSM tree with a real iterator
(`dLSM/benchmarks/ycsbc.cc:357`).

## Paper numbers need 3 runs averaged — this harness does 1

**Every table and figure produced from a single invocation is n=1 and is not
publishable.** Run the sweep three times and average; report the spread.

This is not a formality. Measured run-to-run variation on identical
configurations, comparing two back-to-back sweeps at 3 servers / 1 client /
100k ops:

| arm | run 1 | run 2 | delta |
|---|---|---|---|
| workload A, disco-skip cache-on | 101 | 107 | +6% |
| workload A, disco-skip cache-off | 34 | 35 | +3% |
| workload A, swarm-kv | 150 | 151 | +0.7% |
| workload A, fusee | 114 | 112 | −1.8% |

So the noise floor is roughly **±6% on our arms** and tighter on the others.
Any gap smaller than that is not a result: the first sweep showed swarm-kv
ahead of us by 4% on workload D, which is inside the noise and must not be
reported as a loss. Conversely the B and C margins (11–20%) survive it
comfortably.

Three runs is the minimum that lets you quote a mean with a visible spread.
Use `REPEATS=3`, which writes each repetition to its own results directory and
leaves `summarize.py` to aggregate them; pass several CSVs to
`summarize.py` and it reports mean ± half-range across them rather than a
single number.

## Three traps this harness exists to avoid

**1. The systems do not report throughput in the same units.**

| system | printed | formula | scope |
|---|---|---|---|
| disco-skip | `Local tput: N kops` | `iter*1e6/elapsed` | per client |
| swarm-kv | `Local tput: Nkpos` | `iter*1e6/elapsed` | per client |
| fusee | `aggregated tput: Nkops` | `clients*iter*1e6/elapsed` | **cluster** |
| dLSM ycsbc | `# Transaction throughput (MOPS): x` | `ops/compute_nodes/duration` | **per node**, MOPS |

Comparing the printed numbers directly is wrong by a factor of the client
count. `lib.sh` normalises everything to one definition — **sum of per-client
throughput in kops** — dividing fusee's aggregate by the client count and
summing dLSM's per-node figures with a ×1000 unit fix. (`kpos` is swarm-kv's
own typo and matching `kops` finds nothing in its logs.)

**2. Scan lengths were not comparable.** dLSM hardcoded `scan_len(1, 100)`;
our E set `maxscanlength=8`. Mean ~50 against mean ~4.5. dLSM now reads
`$DLSM_SCAN_LEN_MAX` (defaulting to 100, so an unset build is upstream — see
`bin/dlsm/build.sh` for the one-hunk exception), `run_ycsb.sh` forwards it into
the remote shell, and both sides sweep 8/32/100. Our side also needs
`--maxrange` raised to match, because `OpScan` clamps to `layout.max_range` and
would otherwise truncate every long scan to 10. dLSM's `scan_len` is an 8-bit
bitfield, so 255 is the hard ceiling.

**3. dLSM had no automated deploy path.** `send-deployment.sh` has a branch
that moves `staging/dlsm/out/*` into `bin/dlsm/`, but `zip-binaries.sh` packed
with `-j` (junk paths), so nothing ever created that directory and the branch
was dead. The binaries on the workers were hand-copied and had gone two days
stale against a fresh rebuild — meaning a dLSM measurement silently ran the
wrong build. `zip-binaries.sh` now adds them with their path.

## Per-operation latency, and when to turn it off

`LATENCY=0 ./ycsb-abcd.sh` (or `--latency 0` directly) stops disco-skip timing
individual operations. It removes two `clock_gettime` calls and a profiler
update per op — tens of ns against a ~4 µs operation, so low single-digit
percent, which is worth removing from a pure throughput figure and worth
keeping for anything that plots latency.

**On is the default because it is the fair setting.** swarm-kv records latency
unconditionally (`swarm-kv/src/oops_state.hpp`) and so does fusee (in its run
loop); neither has a switch, so neither can be turned off without editing it. A
disco-skip number measured with `LATENCY=0` next to their numbers is a
disco-skip advantage, not a result. Use it only for figures where every arm is
ours.

The switch gates the *start* timestamp, not just the recording, so it genuinely
removes both clock reads. With it off, the log has no `######## GET stats:` or
`PUT stats:` sections at all — `reportStats()` prints a section only when the
profiler has measurements — so the choice is visible in the data rather than
only in the invocation.

**This was not previously recorded at all.** `SvFuture::begin()` stamped a
start time and exposed it through `isMeasuring()`/`getStart()` for a caller to
use, and no caller ever did; only `RangeFuture` recorded anything. So
`get_profiler` and `put_profiler` were always empty and every benchmark log
contained zero per-operation latency for disco-skip, while the comparison
systems filled theirs in. The failure mode was a *missing section* rather than
a zero, which is why it went unnoticed — a latency panel simply came out blank
for one system.

## What the numbers do and do not say

**The E column is now a real skip-vector measurement** — A10 has landed. Until
it did, `OpScan` went to the register `RangeFuture` over the old flat array
while `OpInsert` went to the skip vector, so the two halves of E touched
disjoint structures and the inserts never grew the thing being scanned. Any E
number from before that carries the caveat and should be discarded.

**Expect a much lower number than the old one.** The register path bulk-read a
flat array; this walks an ordered structure node by node, taking a snapshot and
reading each node's version as of it. The first cluster run came out at **34
kops against the register path's 290**. That is not a regression — it is the
first honest measurement, and the first one comparable with dLSM at all.

**E runs `--ts faa`, not the default clock.** A snapshot and the vectors' `ts`
must come from the same source, and at the measured ε (p99 ≈ 56 µs,
`clock-measurements.md` §8) a clock snapshot would be linearizable only within a
window ~28 operations wide. The counter is exact, and a reader only READs it —
never a fetch-and-add — so concurrent ranges do not contend.

**`capped` is not a warning.** A YCSB scan is count-bounded and the upper key
bound is open, so reaching the entry cap is how a scan that found enough entries
is supposed to end. On a dense keyspace that is very nearly all of them.

**Workload D is not stock D.** Stock D is read 0.95 / insert 0.05 over `latest`.
`oops-workloadd-latest` keeps `latest` and moves the 5% to update, so it
isolates the *distribution* against B. E does use real inserts (95/5
scan/insert, matching dLSM's `ycsb-e`) because there the structure growing
during the run is the point — `main.cpp` now executes run-phase `INSERT`, which
it previously parsed only during load and dropped silently during the run.

**The generators differ for E.** disco-skip drives the real YCSB Java generator
and parses its trace; dLSM's `ycsbc` has its own built-in generator and shards
keys across compute nodes. Same workload *definition*, different draws. Two
measurements of one workload, not paired samples.

**Logs go where the existing figures look for them.** Runs write to
`logs/YCSB/workload-<LETTER>/<SCHEME>/<N>servers/<nc>client/client<c>.txt`, the
layout `experiments/ycsb-all.sh` uses and `plot-datapoints/*.py` reads, with
schemes `DISCO-SKIP`, `DISCO-SKIP-NOCACHE`, `SWARM-KV`, `FUSEE`. An earlier
version of this harness wrote to `compare/<stamp>/...` and produced data no
existing plot script could see. `results/<stamp>/results.csv` is the same data
in one file for ad-hoc plotting.

**Client counts are a sweep, not a single point.** The existing figures are
throughput-vs-clients, so `CLIENT_COUNTS` defaults to `1 2 4 8`; one client is
one point on a line chart.

**Arena sizing bounds run length** on the disco-skip arms: every write
allocates a vector and nothing is reclaimed, so `--vecs-per-client` must cover
the loaded keys plus every write the run issues. An exhausted run is flagged
`ARENA-EXHAUSTED` in the summary and its number is void, not merely low.
