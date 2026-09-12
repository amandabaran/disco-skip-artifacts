#!/usr/bin/env python3
"""Recompute the notes column of a finished results.csv from its stored logs.

    ./rescan-notes.py results/abcd-<stamp>

Notes are written at run time, so a bug in the warning check poisons results
that are otherwise perfectly good -- and a note is not cosmetic: summarize.py
EXCLUDES a flagged arm as void. A loose `grep -i exhaust` once matched the
client's own "N retry-budget exhausted" counter and voided every disco-skip arm
in a completed sweep. This re-derives the notes without re-running anything.

The checks mirror lib.sh's run_warnings; keep them in step.
"""
import csv
import glob
import os
import re
import shutil
import sys


def warnings_for(logdir):
    out = []
    logs = sorted(glob.glob(os.path.join(logdir, "client*.txt")))
    if not logs:
        return ["NO-LOGS"]
    spent = False
    unresolved = False
    crashed = False
    for f in logs:
        try:
            t = open(f, errors="ignore").read()
        except OSError:
            continue
        # Arena: read the numbers, do not match the word. 98% of the stripe is
        # close enough to spent that the tail of the run is not doing real work.
        for m in re.finditer(r"vectors allocated:\s+(\d+) of (\d+)", t):
            used, cap = int(m.group(1)), int(m.group(2))
            if cap > 0 and used >= cap * 0.98:
                spent = True
        if "DID NOT RESOLVE" in t:
            unresolved = True
        if re.search(r"terminate|what\(\):|Segmentation|Unrecognized token", t):
            crashed = True
    if spent:
        out.append("ARENA-EXHAUSTED")
    if unresolved:
        out.append("UNRESOLVED-OPS")
    if crashed:
        out.append("CRASH-OR-BAD-ARGS")
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    csv_path = os.path.join(d, "results.csv")
    rows = list(csv.DictReader(open(csv_path, newline="")))
    if not rows:
        sys.exit(f"no rows in {csv_path}")
    shutil.copy(csv_path, csv_path + ".bak")

    changed = 0
    for r in rows:
        nc = r.get("clients", "")
        for cand in (f"{r['wl']}-{r['system']}-{nc}c", f"{r['wl']}-{r['system']}"):
            logdir = os.path.join(d, cand)
            if os.path.isdir(logdir):
                break
        new = " ".join(warnings_for(logdir))
        if (r.get("notes") or "").strip() != new:
            changed += 1
        r["notes"] = new

    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"rescanned {csv_path}: {changed} of {len(rows)} notes changed "
          f"(backup at {os.path.basename(csv_path)}.bak)")


if __name__ == "__main__":
    main()
