#!/usr/bin/env python3
"""One throughput plot and one latency plot per YCSB workload.

    ./ycsb-per-workload.py                          # newest sweep
    ./ycsb-per-workload.py --runs DIR1 DIR2 DIR3    # mean of three runs
    ./ycsb-per-workload.py --workloads a c          # just these

x is client count; y is throughput (kops) in one figure and mean latency (us)
in the other. Every competitor is its own line, DiSCO-Skip with and without the
cache included as two of them -- the gap between those two is the cache's
entire contribution and it is the most informative pair on most of these
charts.

Lines differ in colour, dash pattern AND marker, so the figures survive being
printed in greyscale.

MULTIPLE RUNS ARE THE INTENDED USE. Pass several results directories and each
point becomes the mean with an error bar showing the half-range. A single run
is n=1: measured variation is up to ~6% on the DiSCO-Skip arms and ~17% on
workload D at 2 clients, so a gap narrower than that is not a result. The
figures say so in the corner when given one run.

Reads experiments/compare/results/<stamp>/, which is where the sweep harness
fetches its client logs. NOT logs/YCSB/ -- that holds older runs of unknown
provenance, and mixing them in would put two experiments on one line.
"""
import argparse
import glob
import os
import sys

from prelude import plt, line_style
from matplotlib.ticker import MaxNLocator
import ycsb_results as R

# Colour + dash + marker, all three, so the lines are distinguishable in
# greyscale and for the colour-blind. The two DiSCO-Skip arms deliberately
# share a hue and differ in dash: they are the same system, configured twice.
STYLE = {
    "disco-skip-cache1":      dict(color="#7b2fbe", linestyle="-",   marker="o"),
    "disco-skip-cache0":      dict(color="#7b2fbe", linestyle=":",   marker="s"),
    "swarm-kv":               dict(color="#3b8df8", linestyle="--",  marker="^"),
    "fusee":                  dict(color="#f4860b", linestyle="-.",  marker="D"),
}

TITLES = {
    "a": "YCSB A (50% read / 50% update)",
    "b": "YCSB B (95% read / 5% update)",
    "c": "YCSB C (100% read)",
    "d": "YCSB D (95/5, latest distribution)",
    "e": "YCSB E (95% scan / 5% insert)",
}


def default_runs():
    """The richest sweep, not merely the newest.

    "Newest" picks whatever was run last, which is often a single re-run of one
    cell -- the first version of this defaulted that way and produced a chart
    with one point on it. Rank by how many cells a directory actually holds and
    break ties by recency.
    """
    dirs = sorted(glob.glob("experiments/compare/results/abcd-*"), reverse=True)
    if not dirs:
        sys.exit("no experiments/compare/results/abcd-* found; run the sweep first")
    def cells(d):
        return len(glob.glob(os.path.join(d, "*-*c")))
    best = max(dirs, key=lambda d: (cells(d), d))
    return [best]


def plot_metric(wl, runs, client_counts, metric, outdir, n_runs):
    """metric is 'tput' or 'lat'."""
    data = R.collect(runs, wl, client_counts)

    fig, ax = plt.subplots(figsize=(3.3, 2.3))
    drew = False
    for arm, label in R.ARMS.items():
        xs, ys, errs = [], [], []
        for nc in client_counts:
            vals = data[arm][nc][metric]
            m, half = R.mean_spread(vals)
            if m is None:
                continue          # absent, not zero -- never invent a point
            xs.append(nc)
            ys.append(m / 1000.0 if metric == "tput" else m)
            errs.append((half / 1000.0 if metric == "tput" else half))
        if not xs:
            continue
        drew = True
        st = STYLE[arm]
        if n_runs > 1 and any(e > 0 for e in errs):
            ax.errorbar(xs, ys, yerr=errs, label=label, capsize=1.5,
                        elinewidth=0.5, **st, **line_style)
        else:
            ax.plot(xs, ys, label=label, **st, **line_style)

    if not drew:
        plt.close(fig)
        return None

    ax.set_xlabel("Clients")
    ax.set_ylabel("Throughput (Mops)" if metric == "tput"
                  else "Mean latency (us)")
    ax.set_title(TITLES.get(wl, wl.upper()), pad=4)
    ax.set_ylim(bottom=0)
    ax.set_xlim(left=0)
    ax.xaxis.set_major_locator(MaxNLocator(integer=True))
    ax.grid(True, linestyle="--", linewidth=0.5, alpha=0.7)
    ax.set_axisbelow(True)
    ax.legend(frameon=True, edgecolor="black", fontsize=6, loc="best")

    if n_runs == 1:
        # Stated on the figure itself, because a chart outlives the shell it was
        # made in and n=1 is the single most important thing about these.
        ax.text(0.99, 0.02, "n=1", transform=ax.transAxes, ha="right",
                va="bottom", fontsize=5, color="#888888")

    os.makedirs(outdir, exist_ok=True)
    name = f"ycsb-{wl}-{'throughput' if metric == 'tput' else 'latency'}.pdf"
    path = os.path.join(outdir, name)
    fig.savefig(path, format="pdf", bbox_inches="tight", pad_inches=0.01)
    plt.close(fig)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", nargs="+", default=None,
                    help="results directories; several are averaged")
    ap.add_argument("--workloads", nargs="+", default=["a", "b", "c", "d"])
    ap.add_argument("--out", default="output-plots")
    args = ap.parse_args()

    runs = args.runs or default_runs()
    for d in runs:
        if not os.path.isdir(d):
            sys.exit(f"not a directory: {d}")
    print(f"{len(runs)} run(s): {', '.join(runs)}")
    if len(runs) < 3:
        print("*** n < 3. These figures are not publishable on their own;")
        print("*** pass three results directories to --runs. See")
        print("*** experiments/compare/README.md.")

    made = []
    for wl in args.workloads:
        ccs = R.discover_client_counts(runs, wl)
        if not ccs:
            print(f"  workload {wl}: no data, skipped")
            continue
        for metric in ("tput", "lat"):
            p = plot_metric(wl, runs, ccs, metric, args.out, len(runs))
            if p:
                made.append(p)
            elif metric == "lat":
                print(f"  workload {wl}: no latency data "
                      f"(runs made with --latency 0, or predating latency "
                      f"recording)")
        print(f"  workload {wl}: clients {ccs}")

    print("\nWrote:")
    for p in made:
        print(f"  {p}")


if __name__ == "__main__":
    main()
