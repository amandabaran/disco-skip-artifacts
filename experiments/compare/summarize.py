#!/usr/bin/env python3
"""Turn a comparison sweep's results.csv into a readable table.

    ./summarize.py results/abcd-<stamp>/results.csv

Reports each system's throughput per workload and disco-skip's ratio against
the best competitor, because "101 vs 113" is the number that matters and a
column of absolutes makes the reader do the division.

Rows carrying a note are NOT silently included in the comparison: an
ARENA-EXHAUSTED or NO-TPUT-PARSED arm has a number that looks like a low
result and is actually a void one, and averaging it in would quietly move the
ratio. They are listed separately.
"""
import csv
import sys
from collections import OrderedDict


def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if not r.get("total_kops"):
                continue
            try:
                r["kops"] = int(r["total_kops"])
            except ValueError:
                continue
            r["note"] = (r.get("notes") or "").strip()
            rows.append(r)
    return rows


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rows = load(sys.argv[1])
    if not rows:
        sys.exit("no parseable rows")

    key = "wl" if "wl" in rows[0] else "scanlen"
    groups = OrderedDict()
    for r in rows:
        groups.setdefault(r[key], []).append(r)

    systems = list(OrderedDict.fromkeys(r["system"] for r in rows))
    w = max(12, max(len(s) for s in systems) + 1)

    print(f"{key:<8}" + "".join(f"{s:>{w}}" for s in systems))
    print("-" * (8 + w * len(systems)))

    voided = []
    for g, rs in groups.items():
        line = f"{g:<8}"
        by_sys = {}
        for s in systems:
            hit = next((r for r in rs if r["system"] == s), None)
            if hit is None:
                line += f"{'-':>{w}}"
            elif hit["note"] and "register-path" not in hit["note"]:
                # A flagged arm is shown but excluded from the ratio below.
                line += f"{str(hit['kops']) + '!':>{w}}"
                voided.append((g, s, hit["note"]))
            else:
                line += f"{hit['kops']:>{w}}"
                by_sys[s] = hit["kops"]
        print(line)

        ours = next((v for k, v in by_sys.items() if k.startswith("disco-skip")
                     and "cache1" in k), None)
        if ours is None:
            ours = next((v for k, v in by_sys.items()
                         if k.startswith("disco-skip")), None)
        others = {k: v for k, v in by_sys.items()
                  if not k.startswith("disco-skip") and v > 0}
        if ours and others:
            best = max(others, key=others.get)
            ratio = ours / others[best]
            verdict = "faster" if ratio >= 1 else "SLOWER"
            print(f"{'':<8}disco-skip(cache1) / {best}: {ratio:.2f}x {verdict}")

    if voided:
        print("\nEXCLUDED FROM THE RATIOS (marked ! above) -- these numbers are")
        print("void, not low:")
        for g, s, note in voided:
            print(f"  {key}={g} {s}: {note}")

    print("\nAll figures are the SUM of per-client kops. fusee's printed value")
    print("is a cluster aggregate and dLSM's is per compute node; lib.sh")
    print("normalises both. See README.md.")


if __name__ == "__main__":
    main()
