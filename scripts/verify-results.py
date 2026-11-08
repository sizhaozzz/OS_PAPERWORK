#!/usr/bin/env python3
"""Check preserved evidence without Docker; optionally regenerate the CSV index."""
import argparse
import csv
import hashlib
import json
import sys
from pathlib import Path

from summarize import CASES, parse_log, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-index", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    rows = []
    for path in sorted((repo / "results").glob("*/summary.json")):
        report = path.parent
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
    if args.write_index:
        with (repo / "results" / "summary.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
    print("PASS: {} workload runs, source hashes, counters, schedules and replay logs".format(len(rows)))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print("FAIL: " + str(error), file=sys.stderr)
        raise SystemExit(1)
