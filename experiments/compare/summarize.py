#!/usr/bin/env python3
"""Turn comparison sweeps' results.csv into a readable table.

    ./summarize.py results/abcd-<stamp>/results.csv                  # one run
    ./summarize.py results/abcd-*/results.csv                        # n runs

Reports each system's throughput per workload and client count, and
disco-skip's ratio against the best competitor, because "101 vs 113" is the
number that matters and a column of absolutes makes the reader do the division.

PASS THREE CSVs FOR ANYTHING GOING IN A PAPER. A single invocation is n=1.
Measured run-to-run variation on identical configurations is up to ~6% on the
disco-skip arms, so a gap smaller than that is not a result -- see README.md.
With several CSVs this prints mean and half-range (mean +/- (max-min)/2) and
marks any comparison whose margin is inside the observed spread as NOISE.

Rows carrying a note are NOT silently included: an ARENA-EXHAUSTED or
NO-TPUT-PARSED arm has a number that looks like a low result and is actually a
void one, and averaging it in would quietly move the ratio. They are listed
separately.
"""
import csv
import sys
from collections import OrderedDict, defaultdict


def load(paths):
    """-> {(group, system): [kops, ...]}, {(group, system): note}, key_name."""
    vals = defaultdict(list)
    notes = {}
    key = None
    for path in paths:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                if not r.get("total_kops"):
                    continue
                try:
                    kops = int(r["total_kops"])
                except ValueError:
                    continue
                if key is None:
                    key = "wl" if "wl" in r else "scanlen"
                # Client count is part of the identity when present: a 1-client
                # and an 8-client arm are different measurements, not repeats.
                nc = r.get("clients") or ""
                group = (r[key], nc)
                note = (r.get("notes") or "").strip()
                if note and "register-path" not in note:
                    notes[(group, r["system"])] = note
                    continue
                vals[(group, r["system"])].append(kops)
    return vals, notes, (key or "wl")


def agg(xs):
    """-> (mean, half_range). half_range is 0 for a single sample."""
    if not xs:
        return None, 0
    return sum(xs) / len(xs), (max(xs) - min(xs)) / 2.0


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    paths = sys.argv[1:]
    vals, notes, key = load(paths)
    if not vals:
        sys.exit("no parseable rows")

    n_runs = len(paths)
    systems = list(OrderedDict.fromkeys(s for (_, s) in vals))
    groups = list(OrderedDict.fromkeys(g for (g, _) in vals))
    w = max(14, max(len(s) for s in systems) + 2)

    print(f"{n_runs} run(s): {', '.join(paths)}")
    if n_runs < 3:
        print("*** n < 3. NOT PUBLISHABLE. Paper numbers need 3 runs averaged;")
        print("*** run-to-run variation is up to ~6% on the disco-skip arms, so")
        print("*** a margin under that is noise. See README.md.")
    print()
    hdr = f"{key:<8}{'clients':>8}" + "".join(f"{s:>{w}}" for s in systems)
    print(hdr)
    print("-" * len(hdr))

    wild = []
    for g in groups:
        line = f"{g[0]:<8}{g[1]:>8}"
        means = {}
        spreads = {}
        for s in systems:
            xs = vals.get((g, s), [])
            m, hr = agg(xs)
            if m is None:
                line += f"{'!' if ((g, s) in notes) else '-':>{w}}"
                continue
            means[s], spreads[s] = m, hr
            if len(xs) > 1 and m > 0 and hr / m > 0.15:
                wild.append((g, s, m, hr))
            cell = f"{m:.0f}" if n_runs == 1 else f"{m:.0f}+-{hr:.0f}"
            line += f"{cell:>{w}}"
        print(line)

        # The primary arm ONLY. Falling back to another disco-skip arm here was
        # a reporting bug: when the cache-on arm was excluded as void, the
        # ratio quietly used the CACHE-OFF number and still labelled it
        # "disco-skip" -- reporting 0.19x for a configuration that had in fact
        # crashed, which reads as a catastrophic result rather than as missing
        # data. If the primary arm has no usable number, there is no ratio.
        ours_name = ("disco-skip-cache1" if "disco-skip-cache1" in means
                     else "disco-skip-reg" if "disco-skip-reg" in means
                     else None)
        ours = means.get(ours_name) if ours_name else None
        if ours is None and any(k.startswith("disco-skip") for k in
                                (n for (_, n) in notes if _ == g)):
            print(f"{'':<16}no ratio: the disco-skip arm is void here")
        others = {k: v for k, v in means.items()
                  if not k.startswith("disco-skip") and v > 0}
        if ours and others:
            best = max(others, key=others.get)
            ratio = ours / others[best]
            # Noise band: the two arms' own spreads, or the measured 6% floor
            # when n=1 and we have no spread of our own to go on.
            band = ((spreads.get("disco-skip-cache1", 0) + spreads.get(best, 0))
                    / others[best]) if n_runs > 1 else 0.06
            if abs(ratio - 1.0) <= band:
                verdict = f"NOISE (margin {abs(ratio-1)*100:.1f}% <= band {band*100:.1f}%)"
            else:
                verdict = "faster" if ratio > 1 else "SLOWER"
            print(f"{'':<16}{ours_name} / {best}: {ratio:.2f}x {verdict}")

    if wild:
        print("\n*** SPREAD OVER 15% OF THE MEAN on:")
        for g, sysname, m, hr in wild:
            print(f"      {key}={g[0]} clients={g[1]} {sysname}: "
                  f"{m:.0f} +- {hr:.0f} ({100*hr/m:.0f}%)")
        print("*** Run-to-run noise on identical settings is ~6%. A spread this")
        print("*** wide usually means the runs were NOT identical -- different")
        print("*** -I/-W, --cache, --async or --latency. Averaging across those")
        print("*** is not a repeat, it is a blend of two experiments. Check the")
        print("*** params.txt of each results directory before trusting the mean.")

    if notes:
        print("\nEXCLUDED (marked ! above) -- these numbers are void, not low:")
        for (g, s), note in notes.items():
            print(f"  {key}={g[0]} clients={g[1]} {s}: {note}")

    print("\nAll figures are the SUM of per-client kops. fusee's printed value")
    print("is a cluster aggregate and dLSM's is per compute node; lib.sh")
    print("normalises both. See README.md.")


if __name__ == "__main__":
    main()
