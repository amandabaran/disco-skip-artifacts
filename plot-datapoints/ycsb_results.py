#!/usr/bin/env python3
"""Read disco-skip comparison sweeps into a plottable shape.

Shared by the per-workload plot scripts so they cannot disagree about what a
number means. The awkward parts live here, and every one of them was a bug
first:

  * THE THREE SYSTEMS DO NOT REPORT THROUGHPUT IN THE SAME UNITS.
        disco-skip  "Local tput: N kops"       iter*1e6/elapsed    PER CLIENT
        swarm-kv    "Local tput: Nkpos"        iter*1e6/elapsed    PER CLIENT
        fusee       "aggregated tput: Nkops"   clients*iter/...    CLUSTER
    Everything is normalised to the sum of per-client kops, which means
    dividing fusee's figure by the client count first. Comparing the printed
    numbers directly is wrong by a factor of the client count. (`kpos` is
    swarm-kv's own typo; matching `kops` silently finds nothing in its logs.)

  * LATENCY CAN BE LEGITIMATELY ABSENT. A run made with --latency 0 has no
    percentile lines at all, and so does any log predating the fix that made
    disco-skip record get/put latency in the first place. That is reported as
    None and skipped, never drawn as zero -- a zero would be an invented
    result.

  * RESULTS LIVE IN experiments/compare/results/<stamp>/, not logs/YCSB/.
    run.sh writes on the WORKER; the sweep harness fetches into its own results
    directory. logs/YCSB/ holds older runs of unknown provenance and must not
    be mixed in.

Averaging several runs is the intended use: pass several results directories
and each point becomes a mean with a spread.
"""
import os
import re
import glob
from collections import defaultdict

# Directory name -> label used in the plots. Cache-on and cache-off are
# deliberately separate competitors: the gap between them is the cache's whole
# contribution, and it is the most informative pair on most of these charts.
ARMS = {
    "disco-skip-cache1": "DiSCO-Skip",
    "disco-skip-cache0": "DiSCO-Skip (no cache)",
    "swarm-kv": "SWARM-KV",
    "fusee": "FUSEE",
}

# Which parser each arm needs, keyed by the directory name.
_TPUT_PATTERNS = {
    "disco-skip-cache1": (r"local tput:\s*(\d+)\s*kops", False),
    "disco-skip-cache0": (r"local tput:\s*(\d+)\s*kops", False),
    "swarm-kv":          (r"local tput:\s*(\d+)\s*kpos", False),
    "fusee":             (r"aggregated tput:\s*(\d+)\s*kops", True),
}


def _parse_client_log(path):
    """-> (tput_raw, mean_latency_us or None) from one client log."""
    if not os.path.exists(path):
        return None, None
    tput = None
    lat_sum = 0.0
    lat_n = 0
    section = None
    with open(path, errors="ignore") as f:
        for line in f:
            clean = line.strip().lower()
            if "get stats:" in clean:
                section = "GET"
            elif "update stats:" in clean or "put stats:" in clean:
                section = "PUT"
            elif "range stats:" in clean:
                section = "RANGE"
            elif "tput:" in clean:
                m = re.search(r"(?:local|aggregated) tput:\s*(\d+)", clean)
                if m:
                    tput = int(m.group(1))
            elif section and "%:" in clean:
                # "50%: 3.210us." -- percentiles of one operation type. The mean
                # over percentiles above the median approximates the typical
                # latency well enough to compare systems, and is what the
                # existing figures in this directory already use.
                m = re.search(r"([0-9.]+)\s*%:\s*([0-9.]+)\s*(us|ns)", clean)
                if m:
                    p, v, unit = float(m.group(1)), float(m.group(2)), m.group(3)
                    if p > 50.0:
                        lat_sum += v if unit == "us" else v / 1000.0
                        lat_n += 1
    return tput, (lat_sum / lat_n if lat_n else None)


def read_cell(results_dir, wl, arm, nclients):
    """One (workload, arm, client-count) cell from one run.

    -> (total_kops, mean_latency_us or None, n_logs_found)
    """
    d = os.path.join(results_dir, f"{wl}-{arm}-{nclients}c")
    if not os.path.isdir(d):
        d = os.path.join(results_dir, f"{wl}-{arm}")   # older layout
        if not os.path.isdir(d):
            return None, None, 0
    pattern, is_aggregate = _TPUT_PATTERNS[arm]
    total = 0
    lats = []
    found = 0
    for c in range(1, nclients + 1):
        raw, lat = _parse_client_log(os.path.join(d, f"client{c}.txt"))
        if raw is None:
            continue
        found += 1
        # fusee prints a cluster-wide figure; recover its per-client rate so the
        # sum below means the same thing for every system.
        total += (raw // nclients) if is_aggregate else raw
        if lat is not None:
            lats.append(lat)
    if found == 0:
        return None, None, 0
    return total, (sum(lats) / len(lats) if lats else None), found


def _voided_cells(results_dir):
    """{(wl, arm, clients)} that results.csv marks as void.

    A flagged arm is NOT a low result, it is an absent one -- UNRESOLVED-OPS
    means operations gave up and the throughput counts them as done;
    ARENA-EXHAUSTED means the run outlived its stripe; CRASH means no data at
    all. Plotting or averaging those silently corrupts the point.

    This is not hypothetical. Workload D at 8 clients was measured twice, once
    before the liveness fix in ds_put_future.hpp (923 kops with 4% of its
    operations unresolved, flagged) and once after (1271, clean). Averaging
    them gives 1097, a number describing no configuration that has ever run.
    """
    import csv as _csv
    path = os.path.join(results_dir, "results.csv")
    bad = set()
    if not os.path.exists(path):
        return bad
    with open(path, newline="") as f:
        for r in _csv.DictReader(f):
            note = (r.get("notes") or "").strip()
            if not note:
                continue
            try:
                nc = int(r.get("clients", "") or 0)
            except ValueError:
                continue
            bad.add((r.get("wl", ""), r.get("system", ""), nc))
    return bad


def collect(results_dirs, wl, client_counts):
    """-> {arm: {nc: {"tput": [...], "lat": [...]}}} across runs.

    Lists, not scalars: several results directories are several runs of the
    same configuration, and the plots show their mean. One run is n=1.
    """
    out = {arm: defaultdict(lambda: {"tput": [], "lat": []}) for arm in ARMS}
    for d in results_dirs:
        voided = _voided_cells(d)
        for arm in ARMS:
            for nc in client_counts:
                if (wl, arm, nc) in voided:
                    continue     # flagged: absent, not low. See _voided_cells.
                t, l, found = read_cell(d, wl, arm, nc)
                if t is None or found < nc:
                    # A partial cell is not a smaller result, it is a broken
                    # one -- a crashed client means the others carried its
                    # share of nothing.
                    continue
                out[arm][nc]["tput"].append(t)
                if l is not None:
                    out[arm][nc]["lat"].append(l)
    return out


def mean_spread(values):
    """-> (mean, half_range). half_range is 0 for a single sample."""
    if not values:
        return None, 0.0
    return sum(values) / len(values), (max(values) - min(values)) / 2.0


def discover_client_counts(results_dirs, wl):
    """Client counts actually present, so the axis matches the data."""
    found = set()
    for d in results_dirs:
        for arm in ARMS:
            for p in glob.glob(os.path.join(d, f"{wl}-{arm}-*c")):
                m = re.search(r"-(\d+)c$", p)
                if m:
                    found.add(int(m.group(1)))
    return sorted(found)
