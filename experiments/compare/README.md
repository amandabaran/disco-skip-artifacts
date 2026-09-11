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

## What the numbers do and do not say

**The E column for disco-skip is not a skip-vector measurement.** There is no
skip-vector range — A10 is deferred — so `OpScan` falls through to the register
`RangeFuture`, the old flat-array structure. The call site says so. It is a
baseline for the register path and must not be presented as a disco-skip result
until A10 lands.

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

**Arena sizing bounds run length** on the disco-skip arms: every write
allocates a vector and nothing is reclaimed, so `--vecs-per-client` must cover
the loaded keys plus every write the run issues. An exhausted run is flagged
`ARENA-EXHAUSTED` in the summary and its number is void, not merely low.
