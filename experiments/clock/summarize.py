#!/usr/bin/env python3
"""Turn measure_tsc_rate.sh output into the numbers the paper needs.

Reports, per host, the measured TSC frequency and its spread across windows
(the spread is the measurement's own error bar, dominated by residual NTP
frequency error). Then the quantity that actually decides the design:

  relative frequency error between the fastest and slowest machine, in ppm,
  and the clock skew that error accumulates over one experiment from a single
  synchronisation point.

Usage: summarize.py results/<timestamp> [run_seconds]
"""
import statistics
import sys
from pathlib import Path

# Experiment duration the accumulated-skew column is quoted for.
DEFAULT_RUN_SECONDS = 10.0


def load(d: Path):
    hosts = {}
    for f in sorted(d.glob("*.txt")):
        rates = []
        for line in f.read_text().split("\n"):
            parts = line.split()
            if len(parts) == 4:
                rates.append(float(parts[3]))
        if rates:
            hosts[f.stem] = rates
    return hosts


def host_key(name):
    digits = "".join(c for c in name if c.isdigit())
    return (int(digits) if digits else 0, name)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = Path(sys.argv[1])
    run_s = float(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_RUN_SECONDS

    hosts = load(d)
    if not hosts:
        sys.exit(f"no results in {d}")

    means = {h: statistics.fmean(r) for h, r in hosts.items()}
    ref = statistics.median(means.values())

    print(f"\nTSC frequency, {len(hosts)} hosts, "
          f"{len(next(iter(hosts.values())))} windows each")
    print(f"reference = fleet median = {ref:,.1f} Hz\n")
    print(f"{'host':>5}  {'mean Hz':>16}  {'spread Hz':>10}  "
          f"{'vs median':>10}")
    for h in sorted(hosts, key=host_key):
        rates = hosts[h]
        spread = max(rates) - min(rates)
        ppm = (means[h] - ref) / ref * 1e6
        print(f"{h:>5}  {means[h]:>16,.1f}  {spread:>10,.1f}  "
              f"{ppm:>+9.2f}p")

    fast = max(means, key=means.get)
    slow = min(means, key=means.get)
    spread_ppm = (means[fast] - means[slow]) / ref * 1e6

    # Worst-case within-host window-to-window variation, as a check that the
    # cross-host spread is real signal and not measurement noise.
    noise_ppm = max((max(r) - min(r)) / ref * 1e6 for r in hosts.values())

    print(f"\nfastest {fast} vs slowest {slow}: {spread_ppm:.2f} ppm")
    print(f"worst within-host window spread:  {noise_ppm:.2f} ppm "
          f"(measurement noise floor)")
    if noise_ppm >= spread_ppm:
        print("  NOTE: noise floor is at or above the cross-host spread, so "
              "the spread is not resolved -- lengthen the window.")

    print(f"\nAccumulated skew from one sync point, at {spread_ppm:.2f} ppm:")
    for t in (1.0, run_s, 60.0):
        print(f"  after {t:>6.0f} s of run: {spread_ppm * t:>9.1f} us")
    print(f"\nFor reference, a disco-skip operation is ~2 us, so the "
          f"worst-pair skew\nreaches one operation width after "
          f"{2.0 / spread_ppm:.2f} s and ends a {run_s:.0f} s run at "
          f"{spread_ppm * run_s / 2.0:.0f}x it.")


if __name__ == "__main__":
    main()
