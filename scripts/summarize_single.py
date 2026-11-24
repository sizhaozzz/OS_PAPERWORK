#!/usr/bin/env python3
"""Summarise the ONE unified extension bundle into CSV/JSON.

Reads only archived logs -> safe to re-run offline. Produces a single table
with one row per run, where each row is tagged by which presentation point it
evidences, plus small security/reproducibility summaries.
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from summarize_claims import parse_experiment_log  # noqa: E402
from summarize import require  # noqa: E402


def write_csv(path, rows):
    if not rows:
        path.write_text("")
        return
    keys = list(rows[0].keys())
    lines = [",".join(keys)]
    for row in rows:
        lines.append(",".join(str(row.get(k, "")) for k in keys))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_time(text):
    # The summary line is: "Time  <last-new-find>  <total>"; take the total.
    m = re.search(r"Time\s+\d+:\d+:[\d.]+\s+(\d+:\d+:[\d.]+)", text)
    if not m:
        return None
    h, minutes, s = m.group(1).split(":")
    return int(h) * 3600 + int(minutes) * 60 + float(s)


def point_for(prog, cpus):
    if cpus:
        return "scalability"
    if prog.startswith("CVE-"):
        return "compatibility"
    return "scalability-baseline"


def summarize_runs(report):
    rows = []
    for log in sorted((report / "matrix").glob("*.log")):
        name = log.name[:-4]
        if name.endswith("-build"):
            continue
        m = re.match(r"^(reorder_\d+|CVE-\d+-\d+)(?:-(all|cpus(.+)))?$", name)
        if not m:
            continue
        prog = m.group(1)
        cpus = (m.group(3) or "").replace("_", "-") if m.group(2) else ""
        parsed = parse_experiment_log(log, 10000)
        t = parse_time(log.read_text(errors="replace"))
        rows.append({
            "program": prog,
            "era": "legacy(2009-2016)" if prog.startswith("CVE-") else "modern(SCTBench)",
            "cpus": cpus or "all",
            "point": point_for(prog, cpus),
            "schedules": parsed["schedules"],
            "bug_found": parsed["bug_found"],
            "timeouts": parsed.get("timeouts", ""),
            "total_s": round(t, 2) if t else "",
        })
    return rows


def summarize_security(report):
    rows = []
    for label in ("privileged", "unprivileged"):
        log = report / "security" / (label + ".log")
        if not log.is_file():
            continue
        text = log.read_text(errors="replace")
        caps = re.search(r"caps=(\S+)", text)
        bit = re.search(r"cap_sys_nice_bit=(\d+)", text)
        if "PROBE_OK" in text:
            probe = "OK"
        elif bit and bit.group(1) == "0":
            probe = "DENIED_EPERM"
        else:
            probe = "unknown"
        rows.append({
            "context": label,
            "cap_eff": caps.group(1) if caps else "",
            "cap_sys_nice_bit": bit.group(1) if bit else "",
            "sched_deadline_probe": probe,
        })
    return rows


def summarize_repro(report):
    fp = report / "repro" / "fingerprint.log"
    out = {}
    if fp.is_file():
        for line in fp.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip().replace(" ", "_")] = v
    return out


def main():
    report = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    require(report.is_dir(), "report directory not found: {}".format(report))
    runs = summarize_runs(report)
    sec = summarize_security(report)
    repro = summarize_repro(report)
    write_csv(report / "single_runs.csv", runs)
    write_csv(report / "single_security.csv", sec)
    (report / "single_repro.json").write_text(
        json.dumps(repro, indent=2) + "\n", encoding="utf-8")
    (report / "single_summary.json").write_text(json.dumps({
        "experiment": "unified single extension: 5 programs x core budgets, one protocol",
        "runs": runs, "security": sec, "reproducibility": repro,
        "points_covered": ["scalability", "compatibility", "security", "reproducibility"],
    }, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"runs": len(runs), "security_rows": len(sec),
                      "points": ["scalability", "compatibility", "security", "reproducibility"]},
                     indent=2))


if __name__ == "__main__":
    main()
