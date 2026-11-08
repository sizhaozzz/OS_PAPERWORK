#!/usr/bin/env python3
"""Parse PERIOD logs, preserve error schedules, and verify representative replays."""
import collections
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


CASES = {
    "doubleFree": ("df", {"double-free"}),
    "CVE-2016-1972": ("2016-1972", {"SEGV", "heap-use-after-free", "double-free"}),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse_log(path):
    text = re.sub(r"\x1b\[[0-9;]*m", "", path.read_text(errors="replace"))
    require("End Testing!" in text, str(path) + ": incomplete run")
    tests = list(map(int, re.findall(
        r"^test\s+(\d+)(?=:|\s+for prefix\b)", text, re.MULTILINE)))
    require(tests and tests == list(range(1, len(tests) + 1)),
            str(path) + ": missing or repeated schedule records")
    error_match = re.search(r"Total Error Interleavings:\s*(\d+)", text)
    timeout_match = re.search(r"Total Timeouts Interleavings:\s*(\d+)", text)
    total_match = re.search(r"^Round\s+\d+\s+(\d+)\s*$", text, re.MULTILINE)
    require(error_match and timeout_match and total_match, str(path) + ": missing counters")
    errors, timeouts, total = (int(m.group(1)) for m in
                              (error_match, timeout_match, total_match))
    types = collections.Counter(re.findall(r"\[Error Found\]: NO\.\d+\s+(\S+)", text))
    first = {}
    current_schedule = None
    for line in text.splitlines():
        test = re.match(r"^test\s+(\d+)(?=:|\s+for prefix\b)", line)
        if test:
            current_schedule = int(test.group(1))
        error = re.search(r"\[Error Found\]: NO\.\d+\s+(\S+)", line)
        if error:
            require(current_schedule is not None, "Error without a schedule")
            first.setdefault(error.group(1), current_schedule)
    require(total == len(tests), str(path) + ": final counter disagrees with records")
    require(errors == sum(types.values()), str(path) + ": error counter mismatch")
    require(timeouts == 0, str(path) + ": unexpected timeout")
    return {
        "schedules": len(tests), "buggy_interleavings": errors,
        "timeouts": timeouts, "bug_types": dict(types),
        "first_bug_schedule": first,
    }


def main():
    if len(sys.argv) != 4:
        raise SystemExit("Usage: summarize.py REPORT WORK UPSTREAM")
    report, work, upstream = map(Path, sys.argv[1:])
    summary = {}
    for label, (binary, required) in CASES.items():
        values = parse_log(report / (label + "-test.log"))
        require(required.issubset(values["bug_types"]), label + ": missing error types")
        if label == "doubleFree":
            require(values["schedules"] == 6 and values["buggy_interleavings"] == 4,
                    "Unexpected doubleFree result")
        schedules = report / "schedules" / label
        schedules.mkdir(parents=True, exist_ok=False)
        errors = sorted((work / label).glob("out_*/Errors/*"))
        require(len(errors) == values["buggy_interleavings"], label + ": missing saved errors")
        for path in errors:
            shutil.copy2(str(path), str(schedules / path.name))
        replays = []
        for bug_type in sorted(required):
            error_file = next(p for p in errors if p.name.endswith("_" + bug_type))
            result = subprocess.run(
                [sys.executable, "-u", str(upstream / "tool/DBDS/run_PDS.py"),
                 "-y", "-r", str(error_file), "./" + binary],
                cwd=str(work / label), stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, timeout=30,
            )
            log = report / (label + "-replay-" + bug_type + ".log")
            log.write_bytes(result.stdout)
            replay_text = result.stdout.decode(errors="replace")
            require(result.returncode == 0, label + ": replay command failed")
            require("ERROR: AddressSanitizer:" in replay_text and bug_type in replay_text,
                    label + ": expected ASan error missing from replay")
            replays.append({
                "type": bug_type,
                "schedule": str(error_file),
                "log": log.name,
            })
        values.update({
            "replays": replays, "work_directory": str(work / label),
            "test_command": "python3 -u $ROOT_DIR/tool/DBDS/run_PDS.py -y -d "
            + ("3 ./df" if label == "doubleFree" else "5 --runs=10000 ./2016-1972"),
        })
        summary[label] = values
    (report / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    print("PASS: fresh builds, schedule exploration, saved error schedules and replay")


if __name__ == "__main__":
    main()
