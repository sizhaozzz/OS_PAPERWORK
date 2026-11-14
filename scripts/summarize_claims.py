#!/usr/bin/env python3
"""Summarize Claim 1 (10 CVEs) and Claim 2 (PERIOD vs Serial) experiment logs."""
import collections
import csv
import json
import math
import re
import shutil
import sys
from pathlib import Path


def mean_stdev(values):
    nums = [v for v in values if v is not None]
    if not nums:
        return None, None
    avg = sum(nums) / float(len(nums))
    if len(nums) < 2:
        return round(avg, 2), 0.0
    var = sum((x - avg) ** 2 for x in nums) / float(len(nums) - 1)
    return round(avg, 2), round(math.sqrt(var), 2)


def parse_experiment_log(path, runs_limit):
    text = re.sub(r"\x1b\[[0-9;]*m", "", path.read_text(errors="replace"))
    exit_match = re.search(r"^EXIT_CODE=(\d+)\s*$", text, re.MULTILINE)
    exit_code = int(exit_match.group(1)) if exit_match else None

    tests = list(map(int, re.findall(
        r"^test\s+(\d+)(?=:|\s+for prefix\b)", text, re.MULTILINE)))
    error_match = re.search(r"Total Error Interleavings:\s*(\d+)", text)
    timeout_match = re.search(r"Total Timeouts Interleavings:\s*(\d+)", text)
    total_match = re.search(r"^Round\s+\d+\s+(\d+)\s*$", text, re.MULTILINE)

    schedules = int(total_match.group(1)) if total_match else len(tests)
    errors = int(error_match.group(1)) if error_match else None
    timeouts = int(timeout_match.group(1)) if timeout_match else None

    types = collections.Counter(re.findall(r"\[Error Found\]: NO\.\d+\s+(\S+)", text))
    first_by_type = {}
    first_any = None
    current_schedule = None
    for line in text.splitlines():
        m_test = re.match(r"^test\s+(\d+)(?=:|\s+for prefix\b)", line)
        if m_test:
            current_schedule = int(m_test.group(1))
        m_err = re.search(r"\[Error Found\]: NO\.\d+\s+(\S+)", line)
        if m_err and current_schedule is not None:
            btype = m_err.group(1)
            first_by_type.setdefault(btype, current_schedule)
            if first_any is None:
                first_any = current_schedule

    if errors is None and types:
        errors = sum(types.values())

    return {
        "log": path.name,
        "completed": "End Testing!" in text,
        "exit_code": exit_code,
        "schedules": schedules,
        "capped": schedules >= runs_limit,
        "buggy_interleavings": errors if errors is not None else 0,
        "timeouts": timeouts if timeouts is not None else 0,
        "bug_found": (errors is not None and errors > 0) or bool(types),
        "bug_types": dict(types),
        "first_error_schedule": first_any,
        "first_bug_by_type": first_by_type,
    }


def collect_schedules(work_rep_dir, dest_dir):
    errors = sorted(work_rep_dir.glob("out_*/Errors/*"))
    if errors:
        dest_dir.mkdir(parents=True, exist_ok=True)
        for p in errors:
            shutil.copy2(str(p), str(dest_dir / p.name))
    return len(errors)


def summarize_c1(report, work, runs_limit):
    c1_dir = report / "c1"
    if not c1_dir.is_dir():
        return {}, []

    by_cve = collections.defaultdict(list)
    for log in sorted(c1_dir.glob("*-PERIOD-rep*.log")):
        m = re.match(r"^(CVE-\d+-\d+)-PERIOD-rep(\d+)\.log$", log.name)
        if not m:
            continue
        cve, rep = m.group(1), int(m.group(2))
        parsed = parse_experiment_log(log, runs_limit)
        parsed["rep"] = rep
        rep_work = work / "c1" / cve / ("rep" + str(rep))
        if rep_work.is_dir():
            parsed["saved_error_files"] = collect_schedules(
                rep_work, report / "schedules" / "c1" / cve / ("rep" + str(rep))
            )
        by_cve[cve].append(parsed)

    summary = {}
    csv_rows = []
    for cve, runs in sorted(by_cve.items()):
        sched_mean, sched_std = mean_stdev([r["schedules"] for r in runs])
        first_mean, first_std = mean_stdev([r["first_error_schedule"] for r in runs])
        buggy_mean, buggy_std = mean_stdev([r["buggy_interleavings"] for r in runs])
        all_types = sorted({t for r in runs for t in r["bug_types"]})
        summary[cve] = {
            "runs": runs,
            "schedules_mean": sched_mean,
            "schedules_stdev": sched_std,
            "first_error_mean": first_mean,
            "first_error_stdev": first_std,
            "buggy_interleavings_mean": buggy_mean,
            "buggy_interleavings_stdev": buggy_std,
            "detected_bug_types": all_types,
            "any_capped": any(r["capped"] for r in runs),
        }
        csv_rows.append({
            "cve": cve,
            "reps": len(runs),
            "detected_bug_types": ";".join(all_types),
            "first_error_mean": first_mean if first_mean is not None else "",
            "first_error_stdev": first_std if first_std is not None else "",
            "schedules_mean": sched_mean if sched_mean is not None else "",
            "schedules_stdev": sched_std if sched_std is not None else "",
            "buggy_interleavings_mean": buggy_mean if buggy_mean is not None else "",
            "buggy_interleavings_stdev": buggy_std if buggy_std is not None else "",
            "any_capped": any(r["capped"] for r in runs),
        })
    return summary, csv_rows


def summarize_c2(report, work, runs_limit):
    c2_dir = report / "c2"
    if not c2_dir.is_dir():
        return {}, []

    by_cfg = collections.defaultdict(list)
    for log in sorted(c2_dir.glob("reorder_*-rep*.log")):
        m = re.match(r"^(reorder_\d+)-(PERIOD|Serial)-rep(\d+)\.log$", log.name)
        if not m:
            continue
        prog, sched, rep = m.group(1), m.group(2), int(m.group(3))
        parsed = parse_experiment_log(log, runs_limit)
        parsed["rep"] = rep
        rep_work = work / "c2" / prog / (sched + "-rep" + str(rep))
        if rep_work.is_dir():
            parsed["saved_error_files"] = collect_schedules(
                rep_work, report / "schedules" / "c2" / prog / (sched + "-rep" + str(rep))
            )
        by_cfg[(prog, sched)].append(parsed)

    summary = {}
    csv_rows = []
    for (prog, sched), runs in sorted(by_cfg.items()):
        sched_mean, sched_std = mean_stdev([r["schedules"] for r in runs])
        first_mean, first_std = mean_stdev([r["first_error_schedule"] for r in runs])
        buggy_mean, buggy_std = mean_stdev([r["buggy_interleavings"] for r in runs])
        key = prog + "_" + sched
        summary[key] = {
            "program": prog,
            "scheduler": sched,
            "runs": runs,
            "bug_found_count": sum(1 for r in runs if r["bug_found"]),
            "schedules_mean": sched_mean,
            "schedules_stdev": sched_std,
            "first_error_mean": first_mean,
            "first_error_stdev": first_std,
            "buggy_interleavings_mean": buggy_mean,
            "buggy_interleavings_stdev": buggy_std,
            "any_capped": any(r["capped"] for r in runs),
        }
        csv_rows.append({
            "program": prog,
            "scheduler": sched,
            "reps": len(runs),
            "bug_found_runs": sum(1 for r in runs if r["bug_found"]),
            "first_error_mean": first_mean if first_mean is not None else "",
            "first_error_stdev": first_std if first_std is not None else "",
            "schedules_mean": sched_mean if sched_mean is not None else "",
            "schedules_stdev": sched_std if sched_std is not None else "",
            "buggy_interleavings_mean": buggy_mean if buggy_mean is not None else "",
            "buggy_interleavings_stdev": buggy_std if buggy_std is not None else "",
            "any_capped": any(r["capped"] for r in runs),
        })
    return summary, csv_rows


def write_csv(path, rows):
    if not rows:
        return
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0].keys()), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main():
    if len(sys.argv) != 4:
        raise SystemExit("Usage: summarize_claims.py REPORT WORK RUNS_LIMIT")
    report = Path(sys.argv[1])
    work = Path(sys.argv[2])
    runs_limit = int(sys.argv[3])

    c1_summary, c1_rows = summarize_c1(report, work, runs_limit)
    c2_summary, c2_rows = summarize_c2(report, work, runs_limit)

    payload = {"c1": c1_summary, "c2": c2_summary}
    (report / "summary.json").write_text(json.dumps(payload, indent=2) + "\n")
    write_csv(report / "c1_summary.csv", c1_rows)
    write_csv(report / "c2_summary.csv", c2_rows)
    print(json.dumps({"c1_programs": len(c1_summary), "c2_configs": len(c2_summary)}, indent=2))


if __name__ == "__main__":
    main()
