#!/usr/bin/env python3
"""Summarize RQ2/RQ3/Critical-Analysis logs into CSV + JSON reports."""
import json
import re
import sys
from pathlib import Path

from summarize_claims import parse_experiment_log, mean_stdev


def parse_time(text):
    """Parse the Total wall-clock time from a run log into seconds.

    PERIOD logs print one line 'Time  HH:MM:SS.f  HH:MM:SS.f' where the first
    stamp is the time of the last new find and the second is the total time.
    We take the last such line (there can be one per round) and the second
    stamp of that line.
    """
    stamps = re.findall(
        r"Time\s+(\d+):(\d+):([\d.]+)\s+(\d+):(\d+):([\d.]+)", text)
    if not stamps:
        return None
    h, m, s = stamps[-1][3:6]  # second stamp of the last Time line = Total
    return int(h) * 3600 + int(m) * 60 + float(s)


def summarize_rq2(report, runs_limit):
    by_prog = {}
    for log in sorted((report / "rq2").glob("*-rep*.log")):
        m = re.match(r"^(.+)-rep(\d+)\.log$", log.name)
        if not m:
            continue
        prog, rep = m.group(1), int(m.group(2))
        parsed = parse_experiment_log(log, runs_limit)
        by_prog.setdefault(prog, []).append(parsed)
    rows = []
    for prog, runs in sorted(by_prog.items()):
        sched_mean, sched_std = mean_stdev([r["schedules"] for r in runs])
        first_mean, first_std = mean_stdev([r["first_error_schedule"] for r in runs])
        rows.append({
            "program": prog,
            "reps": len(runs),
            "bug_found_runs": sum(1 for r in runs if r["bug_found"]),
            "first_error_mean": first_mean if first_mean is not None else "",
            "first_error_stdev": first_std if first_std is not None else "",
            "schedules_mean": sched_mean if sched_mean is not None else "",
            "schedules_stdev": sched_std if sched_std is not None else "",
            "buggy_interleavings_mean": mean_stdev(
                [r["buggy_interleavings"] for r in runs])[0] or "",
            "any_capped": any(r["capped"] for r in runs),
        })
    return rows


def summarize_rq3(report, runs_limit):
    """Bug depth d x period bound grid sensitivity."""
    by_cfg = {}
    for log in sorted((report / "rq3").glob("*-d*-p*-rep*.log")):
        m = re.match(r"^(.+)-d(\d+)-p(\d+)-rep(\d+)\.log$", log.name)
        if not m:
            continue
        prog, d, p, rep = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
        parsed = parse_experiment_log(log, runs_limit)
        by_cfg.setdefault((prog, d, p), []).append(parsed)
    rows = []
    for (prog, d, p), runs in sorted(by_cfg.items()):
        first_mean, _ = mean_stdev([r["first_error_schedule"] for r in runs])
        sched_mean, _ = mean_stdev([r["schedules"] for r in runs])
        rows.append({
            "program": prog,
            "bug_depth_d": d,
            "period_bound": p,
            "reps": len(runs),
            "bug_found_runs": sum(1 for r in runs if r["bug_found"]),
            "first_error_mean": first_mean if first_mean is not None else "",
            "schedules_mean": sched_mean if sched_mean is not None else "",
            "buggy_interleavings_mean": mean_stdev(
                [r["buggy_interleavings"] for r in runs])[0] or "",
            "any_capped": any(r["capped"] for r in runs),
        })
    return rows


def summarize_rq4(report, runs_limit=None):
    """SCHED_DEADLINE micro-benchmark: group raw samples by threads/mode."""
    log = report / "rq4" / "overhead.log"
    if not log.is_file():
        return []
    groups = {}
    for line in log.read_text().splitlines():
        m = re.search(
            r"threads=(\d+) yields=(\d+) deadline=(\d) wall_sec=([\d.]+)", line)
        if not m:
            continue
        nt, ny, mode, wall = int(m.group(1)), int(m.group(2)), int(m.group(3)), float(m.group(4))
        groups.setdefault((nt, ny, mode), []).append(wall)
    rows = []
    for (nt, ny, mode), vals in sorted(groups.items()):
        # Keep full precision: CFS yields are microseconds and mean_stdev()
        # rounds to 2 decimals, which would erase them.
        avg = sum(vals) / len(vals)
        var = sum((x - avg) ** 2 for x in vals) / len(vals)
        rows.append({
            "threads": nt,
            "yields": ny,
            "sched_deadline": bool(mode),
            "reps": len(vals),
            "wall_sec_mean": round(avg, 6),
            "wall_sec_stdev": round(var ** 0.5, 6),
        })
    # Add slowdown column: deadline / CFS at same thread count.
    cfs = {(r["threads"], r["yields"]): r["wall_sec_mean"]
           for r in rows if not r["sched_deadline"]}
    for r in rows:
        if r["sched_deadline"]:
            base = cfs.get((r["threads"], r["yields"]))
            r["slowdown_vs_cfs"] = round(r["wall_sec_mean"] / base, 3) if base else ""
        else:
            r["slowdown_vs_cfs"] = 1.0
    return rows


def write_csv(path, rows):
    if not rows:
        return
    with path.open("w", newline="") as stream:
        import csv
        writer = csv.DictWriter(stream, fieldnames=list(rows[0].keys()),
                                lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: summarize_rq.py REPORT")
    report = Path(sys.argv[1])
    runs_limit = 10000
    rq2 = summarize_rq2(report, runs_limit)
    rq3 = summarize_rq3(report, runs_limit)
    rq4 = summarize_rq4(report)
    write_csv(report / "rq2_summary.csv", rq2)
    write_csv(report / "rq3_summary.csv", rq3)
    write_csv(report / "rq4_summary.csv", rq4)
    (report / "rq_summary.json").write_text(json.dumps({
        "rq2": rq2, "rq3": rq3, "rq4": rq4,
    }, indent=2) + "\n")
    print(json.dumps({
        "rq2_programs": len(rq2), "rq3_configs": len(rq3), "rq4_configs": len(rq4),
    }, indent=2))


if __name__ == "__main__":
    main()
