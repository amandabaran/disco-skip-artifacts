# A single shared RDMA counter: measured

Answers the question left open in
`bin/disco-skip/disco-skip/docs/clock-measurements.md` §6a — what one global
timestamp counter can sustain, in the configuration the real design would use.

**Reproduce:** `./run_hotspot.sh sweep`

## Setup

Server on w1 holding **one** memory region inside **one** process; client
processes on w2… each opening 8 QPs at depth 16, all connecting into that one
server. With `stride=0` every QP on every machine operates on the **same 8-byte
word**. `stride=64` gives each QP its own cache line and is the control.

This is the configuration `ib_atomic_bw` cannot produce — it pairs one client
process with one server process, each with its own region, so its numbers
describe independent addresses.

Hardware: r320, Intel Xeon E5-2450, Mellanox ConnectX-3 (`mlx4`, fw 2.42.5000),
InfiniBand.

## Results

Aggregate Mops/s, summed across client machines, `secs=5`:

| op | addressing | 1 mach | 2 mach | 4 mach | 8 mach |
|---|---|---|---|---|---|
| FAA | shared word | 2.7074 | 2.6412 | 2.6223 | **2.6928** |
| FAA | own cache line | 2.6972 | 2.6932 | 2.6960 | 2.6724 |
| READ | shared word | 6.0548 | 12.2683 | 17.8013 | **26.4962** |
| READ | own cache line | 6.3760 | 12.9193 | 24.1569 | 26.4835 |

Cross-check: the single-machine FAA figure (2.71) matches `ib_atomic_bw`'s 2.70
on the same pair, which is the evidence that this program measures what it
claims to.

## What it says

**1. The FAA ceiling is ~2.7 Mops/s, and it is *not* same-address contention.**
The control settles this: spreading QPs onto their own cache lines is *equally*
flat (2.70 → 2.67). So the limit is the responder NIC's atomic unit, not
serialisation on the shared word. Two consequences:

- **Sharding the counter within one server buys nothing.** Separate cache lines
  hit the same atomic unit. Only separate NICs would help, and a counter split
  across memory servers no longer yields one total order.
- **Contention costs nothing either.** Eight machines hammering one word get the
  same aggregate as one machine — 2.69 vs 2.71. The ceiling is predictable and
  flat rather than degrading under load, which is the good version of a hard
  limit.

This also resolves the older `rdma-scaling-tests` data, which appeared to scale
to ~21 Mops/s: that sweep was on **c6525-25g** (25 GbE RoCE, later silicon).
ConnectX-3 atomics do not scale; do not carry those numbers over.

**2. The reader path is a non-issue.** Reads of a single shared word scale
essentially as well as reads to distinct lines — 26.50 vs 26.48 Mops/s at eight
machines, ~10× the FAA ceiling, with no same-address penalty at all. An earlier
estimate in §6a worried that per-scan counter reads would consume over half a
memory server's read budget; that was based on a 7 Mops/s single-QP figure and
was too pessimistic. At ~4 M scans/s the counter read is ~15% of the counter
server's read capacity.

**3. The binding workload is the write-heavy one, not the scan-heavy one.**
This inverts the earlier expectation. The FAA sits on the **write** path, so:

| workload | write fraction | total ops before FAA saturates |
|---|---|---|
| `oops-workloade*` (95% scan, 5% insert) | 0.05 | ~54 M ops/s — irrelevant |
| `oops-workloada*` (50% read, 50% update) | 0.50 | **~5.4 M ops/s** |

So workload E has ~13× headroom and workload A is where a global FAA counter
would cap aggregate throughput, at roughly 5.4 M ops/s cluster-wide. Whether
that binds depends on what the remote write path actually sustains, which is not
yet measured — F1 does not exist. It is the number to compare against once it
does.

**4. Batching the FAA is not a free lever.** Reserving a block of timestamps per
writer (FAA by 64, hand them out locally) would cut the FAA rate 64× — but it
breaks the property that makes reading the raw counter safe. A reader seeing
`C = 164` would infer every stamp below 164 is published, while the reserving
writer may have published three of its sixty-four. That is the backfill hazard
from §5 again. Any batching scheme needs a published-watermark, not just a
reservation counter.

## Endianness, since this design reads a FAA'd word

The IB spec describes atomic operands in big-endian network order, so the
expectation is that a counter driven by FAA and sampled by RDMA READ needs a
byteswap on the read side. **Measured, it does not.**

```
client:  ops=522046                       (FAAs of 1 it completed)
server:  raw 0x000000000007f73f
         as native (LE) 522047            <-- matches
         as big-endian  4609160440218386432
VERIFY:  RDMA READ back  le=522047        <-- matches
```

Three independent views agree: the client's own count, the server CPU's read of
the word, and an RDMA READ of it. mlx4 performs the read-modify-write in host
byte order on x86, so `ts` needs **no** `be64toh()`.

Worth keeping the check in the program rather than writing the conclusion down
and moving on: this is a device property, not a spec guarantee, so it should be
re-run if the adapter generation ever changes. Had it gone the other way, the
symptom would have been a counter apparently jumping by 2^56 per increment —
which reads as a broken clock rather than a byte-order bug.
