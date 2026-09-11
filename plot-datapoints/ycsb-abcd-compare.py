#!/usr/bin/env python3
"""YCSB A-D: disco-skip vs swarm-kv vs fusee, latency and throughput vs clients.

    ./plot-datapoints/ycsb-abcd-compare.py

Reads the same log layout as ycsb-uniform-3x2.py --
logs/YCSB/workload-<L>/<SCHEME>/<N>servers/<nc>client/client<c>.txt -- and is
deliberately a sibling of it rather than an edit to it: that figure is the
3-workload CHIMERA/DM-ABD comparison and still needs to build.

Differences from ycsb-uniform-3x2.py, all forced by the data:

  * FOUR workloads (A-D). D is oops-workloadd-latest, which is B's 95/5 mix
    with the `latest` distribution -- so a D-vs-B gap is a distribution effect,
    not a mix effect.

  * DISCO-SKIP-NOCACHE is plotted as its own scheme. It is the same binary with
    --cache 0, and it is the most informative line on the chart: it is nearly
    flat across all four workloads, which says the workload sensitivity lives
    in the cache rather than in the remote path.

  * A scheme with no latency data is skipped in the latency panel rather than
    drawn as zero. A disco-skip run made with --latency 0 legitimately has no
    GET/PUT stats sections, and drawing that as 0 µs would invent a result.
"""
import os
import re
import sys

from prelude import plt
from matplotlib.ticker import *
from matplotlib.lines import Line2D

SERVERS_CONFIG = os.environ.get("SERVERS_CONFIG", "3servers")


def parse_log(path):
    """One client log -> {'local tput'|'aggregated tput', 'GET'/'UPDATE' ptiles}.

    Same shape as ycsb-uniform-3x2.py's parser. Two things worth keeping in
    mind, both of which have bitten this comparison:

      * swarm-kv prints `Local tput: {}kpos` -- its own typo, no space -- so the
        regex must not require `kops`.
      * fusee prints an `aggregated tput` that is ALREADY multiplied by the
        client count, while disco-skip and swarm-kv print a per-client `local
        tput`. They are kept as separate keys and reconciled by the caller.
    """
    out = {}
    current = None
    if not os.path.exists(path):
        return out
    with open(path, "r") as f:
        for line in f:
            clean = line.strip().lower()
            if "get stats:" in clean:
                current = "GET"
                out[current] = {"pcount": 0, "psum": 0}
            elif "update stats:" in clean or "put stats:" in clean:
                current = "UPDATE"
                out[current] = {"pcount": 0, "psum": 0}
            elif "local tput:" in clean:
                m = re.search(r"local tput:\s*(\d+)", clean)
                if m:
                    out["local tput"] = int(m.group(1))
            elif "aggregated tput:" in clean:
                m = re.search(r"aggregated tput:\s*(\d+)", clean)
                if m:
                    out["aggregated tput"] = int(m.group(1))
            elif current and "%:" in clean:
                m = re.search(r"([0-9.]+)\s*%:\s*([0-9.]+)\s*(us|ns)", clean)
                if m:
                    perc, val, unit = float(m.group(1)), float(m.group(2)), m.group(3)
                    lat_us = val if unit == "us" else val / 1000.0
                    out[current][perc] = lat_us
                    if perc > 0.5:
                        out[current]["pcount"] += 1
                        out[current]["psum"] += lat_us
    return out


apps = [
    {"title": "YCSB A - 50/50",       "letter": "A"},
    {"title": "YCSB B - 95/5",        "letter": "B"},
    {"title": "YCSB C - 100/0",       "letter": "C"},
    {"title": "YCSB D - 95/5 latest", "letter": "D"},
]

schemes = {
    "DISCO-SKIP":         {"label": "DISCO-SKIP",    "color": "#7b2fbe", "lstyle": "-",  "lwidth": 1.4},
    "DISCO-SKIP-NOCACHE": {"label": "DS (no cache)", "color": "#7b2fbe", "lstyle": ":",  "lwidth": 1.0},
    "SWARM-KV":           {"label": "SWARM-KV",      "color": "#3b8df8", "lstyle": "-",  "lwidth": 0.9},
    "FUSEE":              {"label": "FUSEE",         "color": "#f4860b", "lstyle": "--", "lwidth": 1.2},
}

client_counts = [int(x) for x in
                 os.environ.get("CLIENT_COUNTS", "1 2 4 8 16 32").split()]


def collect(letter, scheme, nc):
    """-> (tput_kops_total, mean_latency_us or None). None means "no data"."""
    get_ops = get_sum = upd_ops = upd_sum = 0
    total_local = 0
    aggregated = None
    seen = False
    for c in range(1, nc + 1):
        path = os.path.join("logs", "YCSB", f"workload-{letter}", scheme,
                            SERVERS_CONFIG, f"{nc}client", f"client{c}.txt")
        d = parse_log(path)
        if not d:
            continue
        seen = True
        if "GET" in d:
            get_ops += d["GET"]["pcount"]
            get_sum += d["GET"]["psum"]
        if "UPDATE" in d:
            upd_ops += d["UPDATE"]["pcount"]
            upd_sum += d["UPDATE"]["psum"]
        if "aggregated tput" in d:
            aggregated = d["aggregated tput"]   # already cluster-wide
        else:
            total_local += d.get("local tput", 0)
    if not seen:
        return None, None
    tput = aggregated if aggregated is not None else total_local
    n = get_ops + upd_ops
    # None, not 0: a --latency 0 run has no percentile lines, and plotting that
    # as zero latency would be a fabricated data point.
    lat = ((get_sum + upd_sum) / n) if n > 0 else None
    return tput, lat


fig, axes = plt.subplots(4, 2, figsize=(3.70, 5.60))
fig.subplots_adjust(top=0.91, bottom=0.07, left=0.14, right=0.96,
                    hspace=0.45, wspace=0.40)

any_latency = False
for row, app in enumerate(apps):
    lat_axis, tput_axis = axes[row, 0], axes[row, 1]
    lat_axis.set_title(f"{app['title']} (Latency)", pad=4, fontsize=7.5)
    tput_axis.set_title(f"{app['title']} (Tput)", pad=4, fontsize=7.5)

    for s, style in schemes.items():
        xs, lats, tputs = [], [], []
        for nc in client_counts:
            tput, lat = collect(app["letter"], s, nc)
            if tput is None:
                continue
            xs.append(nc)
            tputs.append(tput / 1000.0)          # kops -> Mops
            lats.append(lat)
        if not xs:
            continue
        tput_axis.plot(xs, tputs, color=style["color"],
                       linestyle=style["lstyle"], linewidth=style["lwidth"])
        lx = [x for x, l in zip(xs, lats) if l is not None]
        ly = [l for l in lats if l is not None]
        if lx:
            any_latency = True
            lat_axis.plot(lx, ly, color=style["color"],
                          linestyle=style["lstyle"], linewidth=style["lwidth"])

    lat_axis.set_ylabel("Latency (us)", labelpad=2, fontsize=7)
    tput_axis.set_ylabel("Tput (Mops)", labelpad=2, fontsize=7)
    if row == len(apps) - 1:
        lat_axis.set_xlabel("Clients", labelpad=2, fontsize=7)
        tput_axis.set_xlabel("Clients", labelpad=2, fontsize=7)

for row_idx, row in enumerate(axes):
    for sp in row:
        sp.tick_params(axis="both", which="major", pad=2.0, labelsize=7)
        sp.yaxis.set_minor_locator(NullLocator())
        sp.xaxis.set_minor_locator(NullLocator())
        sp.set_xlim(0, max(client_counts) + max(1, max(client_counts) // 16))
        sp.set_ylim(bottom=0)
        sp.grid(True, which="major", axis="both", linestyle="--",
                linewidth=0.5, alpha=0.7)
        sp.set_axisbelow(True)
        sp.tick_params(labelbottom=(row_idx == len(axes) - 1))

fig.legend(handles=[Line2D([0], [0], color=v["color"], linestyle=v["lstyle"],
                           linewidth=v["lwidth"], label=v["label"])
                    for v in schemes.values()],
           bbox_to_anchor=(0.54, 0.96), loc="center", edgecolor="black",
           ncols=2, borderpad=0.20, handletextpad=0.5, fontsize=7)

os.makedirs("output-plots", exist_ok=True)
out = "output-plots/ycsb-abcd-compare.pdf"
plt.savefig(out, format="pdf", bbox_inches="tight", pad_inches=0.01)
print(f"Saved {out}")
if not any_latency:
    print("NOTE: no latency data found in any log -- the latency column is "
          "empty. Either the runs used --latency 0, or they predate "
          "SvFuture::recordIfDone() being added (get/put latency was never "
          "recorded at all before that).", file=sys.stderr)
