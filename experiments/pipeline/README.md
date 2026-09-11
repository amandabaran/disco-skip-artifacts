# Async parallelism: does pipelining raise throughput?

**Reproduce:** `./sweep.sh [iter] [warmup]` (defaults 100000 / 50000).
Results in `results/<timestamp>/`, one log per arm plus `summary.txt`.

## What this measures, and what it does not

Until the skip-vector futures landed, `main.cpp` called `finishAllFutures()`
after **every** operation. The client was therefore synchronous — exactly one
operation in flight — and `--async` had no effect whatever it was set to. This
sweep measures whether it does now.

It is a **throughput** measurement, not a latency one. A traversal is inherently
sequential (level L+1 depends on level L), so pipelining cannot shorten one
operation. What it removes is the client idling through each operation's round
trips.

## Caveats that bound what these numbers mean

- **One client machine, one thread.** So this is per-client throughput, not
  cluster throughput, and it says nothing about the cross-machine staleness that
  `cache-remote-interface.md` §8 analyses as a function of *M*.
- **`target_reg` is now a skip-vector key.** Same integer, different meaning, so
  these are a fresh baseline and **not comparable with any chimera or swarm-kv
  register-path number**.
- **Scan-heavy workloads are not measured here.** `workloade` still runs the
  register `RangeFuture`, because there is no skip-vector range (A10 deferred).
  A scan result would not be a disco-skip measurement at all, so only
  `workloada` (50% read / 50% update) and `workloadc` (100% read) are swept.
- **Arena sizing is load-bearing.** Every write allocates a vector and nothing
  is reclaimed (`invariants.md` §5), so the arena bounds run length. The
  sweep passes `--vecs-per-client 2000000`; an arm that exhausts its stripe
  reports Exhausted and its number is void, which `summary.txt` flags
  explicitly rather than leaving to be noticed.
- **Blocking bootstrap, async measurement.** The population phase runs through
  the same futures, so it is pipelined too; the `--selftest` path is still the
  blocking helpers and unaffected.
