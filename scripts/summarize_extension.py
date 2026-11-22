#!/usr/bin/env python3
"""Summarize depth-bound extension logs into a CSV and JSON report."""
import json
import re
import sys
from pathlib import Path

from summarize_claims import parse_experiment_log


def summarize(report, runs_limit):
    ext_dir = report / "extension"
    by_depth = {}
    for log in sorted(ext_dir.glob("*-d*-rep*.log")):
        m = re.search(r"-d(\d+)-rep(\d+)\.log$", log.name)
        if not m:
            continue
        depth, rep = int(m.group(1)), int(m.group(2))
        parsed = parse_experiment_log(log, runs_limit)
        parsed["rep"] = rep
        parsed["depth"] = depth
        by_depth.setdefault(depth, []).append(parsed)

    rows = []
    detail = {}
    for depth, runs in sorted(by_depth.items()):
        found = [r["schedules"] for r in runs if r["first_error_schedule"] is not None]
        total = [r["schedules"] for r in runs]
        buggy = [r["buggy_interleavings"] for r in runs]

        def mean(vals):
            return round(sum(vals) / float(len(vals)), 2) if vals else None

        rows.append({
            "program": "reorder_5",
            "depth_bound_d": depth,
            "reps": len(runs),
            "bug_found_runs": sum(1 for r in runs if r["bug_found"]),
            "first_error_mean": mean(found) if found else "",
            "total_schedules_mean": mean(total),
            "buggy_interleavings_mean": mean(buggy),
            "any_capped": any(r["capped"] for r in runs),
        })
        detail[depth] = {"runs": runs}

    return rows, detail


def write_csv(path, rows):
    if not rows:
        return
    with path.open("w", newline="") as stream:
        import csv
        writer = csv.DictWriter(stream, fieldnames=list(rows[0].keys()), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: summarize_extension.py REPORT RUNS_LIMIT")
    report = Path(sys.argv[1])
    runs_limit = int(sys.argv[2])
    rows, detail = summarize(report, runs_limit)
    write_csv(report / "extension_summary.csv", rows)
    (report / "extension_summary.json").write_text(json.dumps(detail, indent=2) + "\n")
    print(json.dumps({"depth_points": len(rows)}, indent=2))


if __name__ == "__main__":
    main()
