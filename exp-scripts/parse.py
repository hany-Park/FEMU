#!/usr/bin/env python3
"""Collect run_one.sh results into one CSV row per run.

usage: python3 parse.py ~/femu-results > results.csv

FTL numbers are the measure phase only: snapshot 3 minus snapshot 2 (the
snapshots are taken after fill, warmup and measure). fio numbers come from
measure.json.
"""
import json
import re
import sys
from pathlib import Path

KEY = re.compile(r"FTL-Log: (\w+)\s*:\s*([\d.]+)")

COLS = ["variant", "workload", "rep", "waf", "host", "hot", "hot_ratio",
        "gc_write", "gc_count", "erase", "iops", "bw_MBps",
        "lat_mean_us", "lat_p99_us", "lat_p999_us"]


def snapshots(log):
    """FTL counters of each '=== FEMU FTL SNAPSHOT ===' block, in order."""
    snaps, cur = [], None
    for line in log.read_text(errors="replace").splitlines():
        if "=== FEMU FTL SNAPSHOT ===" in line:
            cur = {}
            snaps.append(cur)
        elif "=== FEMU FTL" in line:
            cur = None  # the periodic STATS blocks are not phase boundaries
        elif cur is not None and (m := KEY.search(line)):
            cur[m.group(1)] = float(m.group(2))
    return snaps


def fio_write(path):
    w = json.loads(path.read_text())["jobs"][0]["write"]
    clat = w["clat_ns"]
    pct = clat.get("percentile", {})
    return {"iops": w["iops"],
            "bw_MBps": w["bw_bytes"] / 1e6,
            "lat_mean_us": clat["mean"] / 1e3,
            "lat_p99_us": pct.get("99.000000", 0) / 1e3,
            "lat_p999_us": pct.get("99.900000", 0) / 1e3}


def main(root):
    print(",".join(COLS))
    for run in sorted(Path(root).glob("*/*/rep*")):
        log, measure = run / "femu.log", run / "measure.json"
        if not log.exists() or not measure.exists():
            print(f"# skip {run}: missing femu.log or measure.json", file=sys.stderr)
            continue
        s = snapshots(log)
        if len(s) < 3:
            print(f"# skip {run}: {len(s)} snapshots, need 3", file=sys.stderr)
            continue
        d = {k: s[2][k] - s[1].get(k, 0) for k in s[2]}
        host = d.get("host_write_pages", 0)
        gc = d.get("gc_write_pages", 0)
        hot = d.get("hot_write_pages", 0)  # absent in baseline -> 0
        row = {"variant": run.parts[-3], "workload": run.parts[-2], "rep": run.name,
               "waf": (host + gc) / host if host else 0.0,
               "host": int(host), "hot": int(hot),
               "hot_ratio": hot / host if host else 0.0,
               "gc_write": int(gc), "gc_count": int(d.get("gc_count", 0)),
               "erase": int(d.get("erase_count", 0)),
               **fio_write(measure)}
        print(",".join(f"{row[c]:.4f}" if isinstance(row[c], float) else str(row[c])
                       for c in COLS))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
