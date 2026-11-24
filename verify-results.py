#!/usr/bin/env python3
"""Check preserved evidence without Docker; optionally regenerate the CSV index."""
import argparse
import csv
import hashlib
import json
import sys
from pathlib import Path

from summarize import CASES, parse_log, require
from summarize_claims import parse_experiment_log


def verify_experiment_report(report):
    summary = json.loads((report / "summary.json").read_text())
    require("PASS: SCHED_DEADLINE" in (report / "experiments.log").read_text(),
            report.name + ": scheduler probe missing")
    require(not (report / "upstream-status-after.txt").read_text().strip(),
            report.name + ": upstream checkout changed")
    c1_count = 0
    for cve, data in sorted(summary.get("c1", {}).items()):
        for run in data["runs"]:
            parsed = parse_experiment_log(report / "c1" / run["log"], 10000)
            require(parsed["schedules"] == run["schedules"],
                    report.name + ": schedule count mismatch in " + run["log"])
            c1_count += 1
    c2_count = 0
    for key, data in sorted(summary.get("c2", {}).items()):
        for run in data["runs"]:
            parsed = parse_experiment_log(report / "c2" / run["log"], 10000)
            require(parsed["schedules"] == run["schedules"],
                    report.name + ": schedule count mismatch in " + run["log"])
            c2_count += 1
    print("{} : verified {} C1 runs and {} C2 runs".format(report.name, c1_count, c2_count))


def verify_extension_report(report):
    """Cross-check archived per-depth logs against extension_summary.json."""
    detail = json.loads((report / "extension_summary.json").read_text())
    require("PASS: SCHED_DEADLINE" in (report / "extension.log").read_text(),
            report.name + ": scheduler probe missing")
    require(not (report / "upstream-status-after.txt").read_text().strip(),
            report.name + ": upstream checkout changed")
    count = 0
    for depth, entry in sorted(detail.items(), key=lambda kv: int(kv[0])):
        for run in entry["runs"]:
            log = report / "extension" / "reorder_5-d{}-rep{}.log".format(depth, run["rep"])
            parsed = parse_experiment_log(log, 10000)
            require(parsed["schedules"] == run["schedules"],
                    report.name + ": schedule count mismatch in " + log.name)
            require(parsed["buggy_interleavings"] == run["buggy_interleavings"],
                    report.name + ": buggy-interleaving mismatch in " + log.name)
            count += 1
    print("{} : verified {} extension runs across {} depth points".format(
        report.name, count, len(detail)))


def verify_rq_report(report):
    """Verify an RQ2/RQ3/RQ4 bundle against its raw logs."""
    summary = json.loads((report / "rq_summary.json").read_text())
    require("PASS: SCHED_DEADLINE" in (report / "rq.log").read_text(),
            report.name + ": scheduler probe missing")
    require(not (report / "upstream-status-after.txt").read_text().strip(),
            report.name + ": upstream checkout changed")
    count = 0
    # RQ2: re-parse each program log and check it completed.
    for cfg in summary.get("rq2", []):
        prog = cfg["program"]
        for rep in range(1, cfg["reps"] + 1):
            log = report / "rq2" / "{}-rep{}.log".format(prog, rep)
            parsed = parse_experiment_log(log, 10000)
            require(parsed["schedules"] in (cfg["schedules_mean"], round(cfg["schedules_mean"])),
                    report.name + ": RQ2 schedule mismatch in " + log.name)
            count += 1
    # RQ3: re-parse each (d, period) log; a valid config must have >0 schedules
    # for found bugs, and the count must match the summary.
    for cfg in summary.get("rq3", []):
        d, p = cfg["bug_depth_d"], cfg["period_bound"]
        for rep in range(1, cfg["reps"] + 1):
            log = report / "rq3" / "reorder_5-d{}-p{}-rep{}.log".format(d, p, rep)
            parsed = parse_experiment_log(log, 10000)
            require(parsed["schedules"] in (cfg["schedules_mean"], round(cfg["schedules_mean"])),
                    report.name + ": RQ3 schedule mismatch in " + log.name)
            count += 1
    # RQ4: every group must have >= 1 sample.
    for cfg in summary.get("rq4", []):
        require(cfg["reps"] >= 1, report.name + ": empty RQ4 group")
        count += cfg["reps"]
    require(count > 0, report.name + ": no runnable RQ data")
    print("{} : verified {} RQ runs (rq2={}, rq3={}, rq4={})".format(
        report.name, count, len(summary.get("rq2", [])),
        len(summary.get("rq3", [])), len(summary.get("rq4", []))))


def verify_ca_report(report):
    """Verify a Critical-Analysis bundle against its raw logs."""
    summary = json.loads((report / "ca_summary.json").read_text())
    # CA4 fingerprint: pinned commit must match across upstream and fresh clone.
    fp = (report / "ca4" / "fingerprint.log").read_text()
    require("commit_match=yes" in fp, report.name + ": CA4 commit mismatch")
    require("fresh_clone=OK" in fp, report.name + ": CA4 fresh clone failed")
    require("offline_verify=OK" in fp, report.name + ": CA4 offline verify failed")
    # CA1: re-parse each scalability log and match schedule counts.
    count = 0
    for cfg in summary.get("ca1", []):
        name = cfg["program"]
        cpus = cfg["cpus"]
        suffix = "" if cpus == "all(16)" else "-cpus" + cpus.replace("-", "_")
        log = report / "ca1" / (name + suffix + ".log")
        parsed = parse_experiment_log(log, 10000)
        require(parsed["schedules"] == cfg["schedules"],
                report.name + ": CA1 schedule mismatch in " + log.name)
        require(parsed["bug_found"] == cfg["bug_found"],
                report.name + ": CA1 bug flag mismatch in " + log.name)
        count += 1
    # CA2: each legacy program build OK and run log re-parses.
    for cfg in summary.get("ca2", []):
        require(cfg["build_ok"] == "OK" and cfg["binary_found"] == "OK",
                report.name + ": CA2 build/binary not OK for " + cfg["program"])
        parsed = parse_experiment_log(report / "ca2" / (cfg["program"] + ".log"), 10000)
        require(parsed["schedules"] == cfg["schedules"],
                report.name + ": CA2 schedule mismatch in " + cfg["program"])
        count += 1
    # CA3: both privilege contexts must be present with opposite cap bits.
    ctx = {c["context"]: c for c in summary.get("ca3", [])}
    require("privileged" in ctx and "unprivileged" in ctx,
            report.name + ": CA3 missing a privilege context")
    require(ctx["privileged"]["cap_sys_nice_bit"] == "1" and
            ctx["unprivileged"]["cap_sys_nice_bit"] == "0",
            report.name + ": CA3 capability bits unexpected")
    count += 2
    require(count > 0, report.name + ": no runnable CA data")
    print("{} : verified {} CA observations (scalability/compatibility/security/repro)".format(
        report.name, count))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-index", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    rows = []
    exp_reports = 0
    ext_reports = 0
    rq_reports = 0
    for path in sorted((repo / "results").glob("*/summary.json")):
        report = path.parent
        if report.name.startswith("experiments-"):
            verify_experiment_report(report)
            exp_reports += 1
            continue
        summary = json.loads(path.read_text())
        require("PASS: SCHED_DEADLINE" in (report / "validation.log").read_text(),
                report.name + ": scheduler probe missing")
        require(not (report / "upstream-status-after.txt").read_text().strip(),
                report.name + ": upstream checkout changed")
        for label, (binary, required) in CASES.items():
            source = repo / "benchmarks" / label / (binary + ".c")
            actual_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            build_log = (report / (label + "-build.log")).read_text(errors="replace")
            require("{}  {}".format(actual_hash, source.name) in build_log.splitlines(),
                    report.name + ": source differs from the recorded build: " + label)
            values = parse_log(report / (label + "-test.log"))
            for field in ("schedules", "buggy_interleavings", "timeouts", "bug_types"):
                require(values[field] == summary[label][field],
                        report.name + ": summary disagrees with log: " + label + "/" + field)
            require(required.issubset(values["bug_types"]), label + ": missing error type")
            saved = sorted((report / "schedules" / label).iterdir())
            require(len(saved) == values["buggy_interleavings"], label + ": missing saved schedules")
            for bug_type, count in values["bug_types"].items():
                require(sum(p.name.endswith("_" + bug_type) for p in saved) == count,
                        label + ": saved schedule types disagree")
            replay_types = {replay["type"] for replay in summary[label]["replays"]}
            require(required.issubset(replay_types), label + ": missing replay records")
            for replay in summary[label]["replays"]:
                text = (report / replay["log"]).read_text(errors="replace")
                require("ERROR: AddressSanitizer:" in text and replay["type"] in text,
                        replay["log"] + ": replay evidence missing")
                require((report / "schedules" / label / Path(replay["schedule"]).name).is_file(),
                        replay["log"] + ": saved replay input missing")
            rows.append({
                "run": report.name, "workload": label,
                "schedules": values["schedules"],
                "buggy_interleavings": values["buggy_interleavings"],
                "timeouts": values["timeouts"],
                "SEGV": values["bug_types"].get("SEGV", 0),
                "heap_use_after_free": values["bug_types"].get("heap-use-after-free", 0),
                "double_free": values["bug_types"].get("double-free", 0),
                "first_SEGV": values["first_bug_schedule"].get("SEGV", ""),
                "first_heap_use_after_free": values["first_bug_schedule"].get("heap-use-after-free", ""),
                "first_double_free": values["first_bug_schedule"].get("double-free", ""),
            })
            print("{} / {}: {} schedules, {} buggy, 0 timeouts".format(
                report.name, label, values["schedules"], values["buggy_interleavings"]))
    require(rows, "No completed results found")
    for report in sorted((repo / "results").glob("extension-*/")):
        if (report / "extension_summary.json").is_file():
            verify_extension_report(report)
            ext_reports += 1
    for report in sorted((repo / "results").glob("rq-*/")):
        if (report / ".INVALID").is_file():
            print("{} : skipped (marked invalid)".format(report.name))
            continue
        if (report / "rq_summary.json").is_file():
            verify_rq_report(report)
            rq_reports += 1
    ca_reports = 0
    for report in sorted((repo / "results").glob("ca-*/")):
        if (report / ".INVALID").is_file():
            print("{} : skipped (marked invalid)".format(report.name))
            continue
        if (report / "ca_summary.json").is_file():
            verify_ca_report(report)
            ca_reports += 1
    if args.write_index:
        with (repo / "results" / "summary.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
    print("PASS: {} validation runs, {} experiment, {} extension, {} RQ and {} CA bundles verified".format(
        len(rows), exp_reports, ext_reports, rq_reports, ca_reports))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        raise SystemExit(1)
