#!/usr/bin/env python3
"""Generate SVG figures from archived CSVs (standard library only, no deps).

Figures:
  figures/fig1_c1_first_error.svg  - schedules to first bug per CVE
  figures/fig2_c2_schedules.svg    - PERIOD vs Serial total schedules (log scale)
  figures/fig3_c2_reduction.svg    - schedule-space reduction by thread count
  figures/fig4_extension_depth.svg - extension: schedules to first bug vs depth bound d

Bundle selection is automatic and content-based: the C2 bundle whose Serial
column is populated is used, so the stale early C2 summary in the 'all' bundle
(Serial = 0) is never plotted.
"""
import csv
import html
import math
from pathlib import Path

INK = "#1f2933"
MUTED = "#52606d"
GRID = "#d9e2ec"
PERIOD = "#0f6e56"
SERIAL = "#b23a2b"
PAPER = "#9aa5b1"


def repo_root():
    return Path(__file__).resolve().parents[1]


def read_csv(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def find_c1():
    for path in sorted(repo_root().joinpath("results").glob("*/c1_summary.csv")):
        rows = read_csv(path)
        if rows:
            return rows
    raise SystemExit("No c1_summary.csv with data found")


def find_c2():
    """Pick the C2 CSV that actually contains Serial results."""
    candidates = []
    for path in sorted(repo_root().joinpath("results").glob("*/c2_summary.csv")):
        rows = read_csv(path)
        if rows and any(r.get("scheduler") == "Serial" and
                        float(r.get("schedules_mean") or 0) > 0 for r in rows):
            candidates.append((path, rows))
    if not candidates:
        raise SystemExit("No c2_summary.csv with populated Serial results found")
    # Prefer a dedicated c2 bundle over the combined all-experiments bundle.
    candidates.sort(key=lambda item: "experiments-c2" not in item[0].name)
    return candidates[0][1]


def find_extension():
    """Return extension summary rows from the newest archived bundle."""
    paths = sorted(repo_root().joinpath("results").glob("extension-*/extension_summary.csv"))
    if not paths:
        return []
    return read_csv(paths[-1])


def esc(text):
    return html.escape(str(text))


def svg_open(width, height, title):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d" font-family="Helvetica, Arial, sans-serif">'
        '<rect width="100%%" height="100%%" fill="#ffffff"/>'
        '<title>%s</title>' % (width, height, width, height, esc(title))
    )


def fig1(rows):
    rows = sorted(rows, key=lambda r: float(r.get("first_error_mean") or 0))
    width = 760
    top, bottom = 56, 36
    left = 150
    bar_h, gap = 22, 9
    height = top + len(rows) * (bar_h + gap) + bottom
    maxv = max([float(r.get("first_error_mean") or 0) +
                float(r.get("first_error_stdev") or 0) for r in rows] + [1])
    scale_max = math.ceil(maxv / 2.0) * 2
    plot_w = width - left - 70

    out = [svg_open(width, height, "C1: schedules to first error per CVE")]
    out.append('<text x="%d" y="28" font-size="17" font-weight="600" fill="%s">'
               'C1: schedules to the first error (mean +/- stdev, 3 runs)</text>'
               % (left, INK))
    out.append('<text x="%d" y="45" font-size="11" fill="%s">'
               'PERIOD, d=5, budget 10,000; lower is faster</text>' % (left, MUTED))

    for tick in range(0, scale_max + 1, 2):
        x = left + plot_w * tick / scale_max
        out.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s" '
                   'stroke-width="1"/>' % (x, top - 6, x, height - bottom + 2, GRID))
        out.append('<text x="%.1f" y="%d" font-size="11" fill="%s" '
                   'text-anchor="middle">%d</text>' % (x, height - bottom + 18, MUTED, tick))

    for i, row in enumerate(rows):
        y = top + i * (bar_h + gap)
        mean = float(row.get("first_error_mean") or 0)
        std = float(row.get("first_error_stdev") or 0)
        bw = plot_w * mean / scale_max
        out.append('<text x="%d" y="%.1f" font-size="12" fill="%s" '
                   'text-anchor="end">%s</text>'
                   % (left - 10, y + bar_h * 0.65, INK, esc(row["cve"])))
        out.append('<rect x="%d" y="%.1f" width="%.1f" height="%d" rx="2" fill="%s"/>'
                   % (left, y, bw, bar_h, PERIOD))
        if std:
            ew = plot_w * std / scale_max
            cx = left + bw
            out.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" '
                       'stroke-width="1.5"/>' % (cx - ew, y + bar_h / 2,
                                                 cx + ew, y + bar_h / 2, INK))
        out.append('<text x="%.1f" y="%.1f" font-size="11" fill="%s">%.2f &#177; %.2f</text>'
                   % (left + bw + 6, y + bar_h * 0.7, MUTED, mean, std))

    out.append('<text x="%d" y="%d" font-size="10" fill="%s">schedules</text>'
               % (left, height - 8, MUTED))
    out.append('</svg>')
    return "\n".join(out)


def fig2(rows):
    by_prog = {}
    for row in rows:
        by_prog.setdefault(row["program"], {})[row["scheduler"]] = row
    programs = ["reorder_3", "reorder_4", "reorder_5", "reorder_10"]
    programs = [p for p in programs if p in by_prog]
    if not programs:
        programs = sorted(by_prog)

    width, height = 760, 440
    left, right, top, bottom = 70, 24, 70, 70
    plot_w = width - left - right
    plot_h = height - top - bottom

    def log_y(v):
        v = max(float(v), 1)
        return top + plot_h * (1 - math.log10(v) / 4.0)

    out = [svg_open(width, height, "C2: PERIOD vs Serial total schedules")]
    out.append('<text x="%d" y="28" font-size="17" font-weight="600" fill="%s">'
               'C2: total schedules explored (log scale, mean, 3 runs)</text>' % (left, INK))
    out.append('<text x="%d" y="46" font-size="11" fill="%s">'
               'PERIOD parallel vs Serial; reorder_10 Serial capped at 10,000</text>'
               % (left, MUTED))

    for decade in range(0, 5):
        v = 10 ** decade
        y = log_y(v)
        label = "10,000+" if decade == 4 else ("{:,.0f}".format(v))
        out.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="%s"/>'
                   % (left, y, width - right, y, GRID))
        out.append('<text x="%d" y="%.1f" font-size="11" fill="%s" '
                   'text-anchor="end">%s</text>' % (left - 8, y + 4, MUTED, label))

    group_w = plot_w / len(programs)
    bar_w = min(group_w * 0.28, 46)
    for idx, prog in enumerate(programs):
        cx = left + group_w * (idx + 0.5)
        vals = []
        for sched, color in (("PERIOD", PERIOD), ("Serial", SERIAL)):
            row = by_prog[prog].get(sched)
            v = float(row["schedules_mean"]) if row else 0
            vals.append((sched, color, v))
        for j, (sched, color, v) in enumerate(vals):
            x = cx - bar_w - 4 + j * (bar_w + 8)
            y = log_y(v) if v > 0 else top + plot_h
            h = (top + plot_h) - y
            out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="2" '
                       'fill="%s"/>' % (x, y, bar_w, h, color))
            label = "{:,.0f}".format(v)
            out.append('<text x="%.1f" y="%.1f" font-size="10" fill="%s" '
                       'text-anchor="middle">%s</text>'
                       % (x + bar_w / 2, y - 5, INK, label))
        out.append('<text x="%.1f" y="%d" font-size="12" fill="%s" '
                   'text-anchor="middle">%s</text>'
                   % (cx, height - bottom + 20, INK, esc(prog)))

    legend_y = height - 20
    for j, (label, color) in enumerate((("PERIOD", PERIOD), ("Serial", SERIAL))):
        x = left + j * 150
        out.append('<rect x="%d" y="%d" width="14" height="12" rx="2" fill="%s"/>'
                   % (x, legend_y - 10, color))
        out.append('<text x="%d" y="%d" font-size="11" fill="%s">%s</text>'
                   % (x + 20, legend_y, MUTED, label))
    out.append('</svg>')
    return "\n".join(out)


def fig3(rows):
    by_prog = {}
    for row in rows:
        if row["scheduler"] == "PERIOD":
            by_prog[row["program"]] = float(row["schedules_mean"])
    serial = {}
    for row in rows:
        if row["scheduler"] == "Serial":
            serial[row["program"]] = float(row["schedules_mean"])
    programs = [p for p in ("reorder_3", "reorder_4", "reorder_5", "reorder_10")
                if p in by_prog and p in serial]
    reductions = []
    for p in programs:
        r = (1 - by_prog[p] / serial[p]) * 100 if serial[p] else 0
        reductions.append((p, r))

    width, height = 760, 420
    left, right, top, bottom = 70, 24, 70, 66
    plot_w = width - left - right
    plot_h = height - top - bottom
    out = [svg_open(width, height, "C2: schedule-space reduction")]
    out.append('<text x="%d" y="28" font-size="17" font-weight="600" fill="%s">'
               'C2: schedule-space reduction from parallel last period</text>' % (left, INK))
    out.append('<text x="%d" y="46" font-size="11" fill="%s">'
               '1 - PERIOD/Serial; reorder_10 uses the capped Serial value (lower bound)</text>'
               % (left, MUTED))

    for tick in range(0, 101, 20):
        y = top + plot_h * (1 - tick / 100.0)
        out.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="%s"/>'
                   % (left, y, width - right, y, GRID))
        out.append('<text x="%d" y="%.1f" font-size="11" fill="%s" '
                   'text-anchor="end">%d%%</text>' % (left - 8, y + 4, MUTED, tick))

    group_w = plot_w / len(reductions)
    bar_w = min(group_w * 0.45, 70)
    for idx, (prog, red) in enumerate(reductions):
        cx = left + group_w * (idx + 0.5)
        h = plot_h * red / 100.0
        x = cx - bar_w / 2
        y = top + plot_h - h
        out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="2" '
                   'fill="%s"/>' % (x, y, bar_w, h, PERIOD))
        out.append('<text x="%.1f" y="%.1f" font-size="11" fill="%s" '
                   'text-anchor="middle">%.1f%%</text>'
                   % (cx, y - 6, INK, red))
        out.append('<text x="%.1f" y="%d" font-size="12" fill="%s" '
                   'text-anchor="middle">%s</text>'
                   % (cx, height - bottom + 20, INK, esc(prog)))
    out.append('</svg>')
    return "\n".join(out)


def fig4(rows):
    """Schedules to first error vs depth bound d (extension experiment)."""
    if not rows:
        return None
    rows = sorted(rows, key=lambda r: int(r["depth_bound_d"]))
    width, height = 720, 420
    left, right, top, bottom = 70, 24, 76, 74
    plot_w = width - left - right
    plot_h = height - top - bottom

    vals = {}
    for r in rows:
        v = r.get("first_error_mean")
        vals[int(r["depth_bound_d"])] = float(v) if v not in ("", None) else 0.0
    depths = sorted(vals)
    maxv = max(list(vals.values()) + [1])
    scale_max = math.ceil(maxv / 50.0) * 50

    out = [svg_open(width, height, "Extension: schedules to first error vs depth bound")]
    out.append('<text x="%d" y="28" font-size="17" font-weight="600" fill="%s">'
               'Extension: schedules to first error vs depth bound d</text>' % (left, INK))
    out.append('<text x="%d" y="46" font-size="11" fill="%s">'
               'reorder_5, PERIOD, 3 runs per depth; d=2 finds it at 41, d>=3 saturates at 225</text>'
               % (left, MUTED))

    for tick in range(0, scale_max + 1, 50):
        y = top + plot_h * (1 - tick / scale_max)
        out.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="%s"/>'
                   % (left, y, width - right, y, GRID))
        out.append('<text x="%d" y="%.1f" font-size="11" fill="%s" '
                   'text-anchor="end">%d</text>' % (left - 8, y + 4, MUTED, tick))

    group_w = plot_w / len(depths)
    bar_w = min(group_w * 0.45, 80)
    for idx, d in enumerate(depths):
        cx = left + group_w * (idx + 0.5)
        v = vals[d]
        h = plot_h * v / scale_max
        x = cx - bar_w / 2
        y = top + plot_h - h
        color = PERIOD if d == 2 else "#2f6f8f"
        out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="2" '
                   'fill="%s"/>' % (x, y, bar_w, h, color))
        out.append('<text x="%.1f" y="%.1f" font-size="12" fill="%s" '
                   'text-anchor="middle">%.0f</text>' % (cx, y - 6, INK, v))
        out.append('<text x="%.1f" y="%d" font-size="12" fill="%s" '
                   'text-anchor="middle">d=%d</text>' % (cx, height - bottom + 20, INK, d))
    out.append('<text x="%d" y="%d" font-size="10" fill="%s">schedules to first error</text>'
               % (left, height - 8, MUTED))
    out.append('</svg>')
    return "\n".join(out)


def main():
    fig_dir = repo_root() / "figures"
    fig_dir.mkdir(exist_ok=True)
    outputs = {
        "fig1_c1_first_error.svg": fig1(find_c1()),
        "fig2_c2_schedules.svg": fig2(find_c2()),
        "fig3_c2_reduction.svg": fig3(find_c2()),
    }
    ext = fig4(find_extension())
    if ext is not None:
        outputs["fig4_extension_depth.svg"] = ext
    for name, content in outputs.items():
        (fig_dir / name).write_text(content + "\n", encoding="utf-8")
        print("wrote figures/" + name)


if __name__ == "__main__":
    main()
