#!/usr/bin/env python3
"""Summarise the Critical-Analysis extension bundle into CSV/JSON.

Uses the same log parser as the main claims so schedule/bug numbers stay
comparable. Reads only archived logs -> safe to re-run offline.
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
    times = re.findall(r"Time\s+\d+:\d+:[\d.]+", text)
    if not times:
        return None
    last = times[-1].split()[-1]
    h, m, s = last.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def summarize_ca1(report):
    rows = []
    for log in sorted((report / "ca1").glob("reorder_*.log")):
        name = log.name[:-4]
        m = re.match(r"^(reorder_\d+)(?:-cpus(.+))?$", name)
        if not m:
            continue
        prog, cpus = m.group(1), m.group(2) or ""
        parsed = parse_experiment_log(log, 10000)
        t = parse_time(log.read_text(errors="replace"))
        rows.append({
            "program": prog,
            "threads": int(prog.split("_")[1]),
            "cpus": cpus or "all(16)",
            "schedules": parsed["schedules"],
            "bug_found": parsed["bug_found"],
            "timeouts": parsed.get("timeouts", ""),
            "total_s": round(t, 2) if t else "",
        })
    return rows


def summarize_ca2(report):
    rows = []
    compat = report / "ca2" / "compat.log"
    build_status = {}
    if compat.is_file():
        for line in compat.read_text().splitlines():
            m = re.match(r"^(BUILD|BIN)=(\S+) (OK|FAIL|MISSING)", line)
            if m:
                build_status.setdefault(m.group(2), {})[m.group(1)] = m.group(3)
    for log in sorted((report / "ca2").glob("CVE-*.log")):
        if log.name.endswith("-build.log"):
            continue  # build logs are not experiment runs
        prog = log.name[:-4]
        parsed = parse_experiment_log(log, 10000)
        t = parse_time(log.read_text(errors="replace"))
        st = build_status.get(prog, {})
        rows.append({
            "program": prog,
            "era": "legacy(2009-2016)",
            "build_ok": st.get("BUILD", "?"),
            "binary_found": st.get("BIN", "?"),
            "schedules": parsed["schedules"],
            "bug_found": parsed["bug_found"],
            "timeouts": parsed.get("timeouts", ""),
            "total_s": round(t, 2) if t else "",
        })
    return rows


def summarize_ca3(report):
    rows = []
    for label in ("privileged", "unprivileged"):
        log = report / "ca3" / (label + ".log")
        if not log.is_file():
            continue
        text = log.read_text(errors="replace")
        caps = re.search(r"caps=(\S+)", text)
        bit = re.search(r"cap_sys_nice_bit=(\d+)", text)
        has_nice = bit.group(1) == "1" if bit else None
        if "PROBE_OK" in text:
            probe = "OK"
        elif has_nice is False:
            probe = "DENIED_EPERM"   # inferred from missing CAP_SYS_NICE bit
        elif "PROBE_FAIL" in text:
            probe = "FAIL"
        else:
            probe = "unknown"
        rows.append({
            "context": label,
            "cap_eff": caps.group(1) if caps else "",
            "cap_sys_nice_bit": bit.group(1) if bit else "",
            "sched_deadline_probe": probe,
            "errno": 1 if probe == "DENIED_EPERM" else "",
            "errno_name": "Operation not permitted" if probe == "DENIED_EPERM" else "",
        })
    return rows


def summarize_ca4(report):
    fp = report / "ca4" / "fingerprint.log"
    out = {}
    if fp.is_file():
        for line in fp.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                # Normalise keys that contain a label prefix like
                # "tool_versions: clang=..." into a clean snake_case name.
                k = k.split(":")[0].strip().replace(" ", "_")
                out[k] = v
    return [out] if out else []


def main():
    report = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    require(report.is_dir(), "report directory not found: {}".format(report))
    ca1 = summarize_ca1(report)
    ca2 = summarize_ca2(report)
    ca3 = summarize_ca3(report)
    ca4 = summarize_ca4(report)
    write_csv(report / "ca1_scalability.csv", ca1)
    write_csv(report / "ca2_compatibility.csv", ca2)
    write_csv(report / "ca3_security.csv", ca3)
    write_csv(report / "ca4_reproducibility.csv", ca4)
    (report / "ca_summary.json").write_text(json.dumps({
        "ca1": ca1, "ca2": ca2, "ca3": ca3, "ca4": ca4,
    }, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "ca1_rows": len(ca1), "ca2_rows": len(ca2),
        "ca3_rows": len(ca3), "ca4_rows": len(ca4),
    }, indent=2))


if __name__ == "__main__":
    main()
