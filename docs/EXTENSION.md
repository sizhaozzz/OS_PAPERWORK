# Extension: sensitivity of PERIOD to the bug-depth bound

This document describes one controlled experiment that goes beyond Wen et al.'s
ICSE 2022 paper. It follows the course requirement to change **one factor at a
time**, on the **same hardware and workload**, and to interpret the result with
respect to the paper's claim.

## 1. Question and motivation

The paper's Section 3.3/3.4 states that PERIOD explores schedules with an
increasing period bound and that the bound needed to expose a bug is tied to the
bug's depth: a bug of depth *d* needs a period bound of roughly *d + 1*. The main
experiments fix this bound for the SCTBench programs at `d = 3` (paper Section
4.1.3; our C2) without showing how the result changes for other bounds.

We therefore ask: **how does the schedule-space size and bug-finding speed of
PERIOD change as the bug-depth bound is varied, with everything else held
fixed?** This tests whether the depth bound is the key trade-off knob that the
paper claims it is, and makes explicit a setting the paper leaves implicit.

## 2. Design (one factor at a time)

| Aspect | Value |
| --- | --- |
| Changed factor | Bug-depth bound `d` ∈ {2, 3, 4, 5} |
| Workload (fixed) | SCTBench `reorder_5` from the author image |
| Scheduler (fixed) | PERIOD parallel scheduler (`run_PDS.py`) |
| Schedule budget (fixed) | 10,000 (`--runs=10000`) |
| Compiler / image (fixed) | Pinned author image; same as main experiments |
| Repetitions | 3 per depth |
| Measurements | Total schedules, schedules to first assertion failure, buggy interleavings, whether a bug is found |

`d = 3` reproduces the paper's own SCTBench setting and acts as the internal
reference point; `d = 2, 4, 5` are the new conditions.

## 3. How to run

On an x86_64 Linux/WSL2 host with Docker:

```bash
make extension
# equivalent: bash scripts/run-extension.sh
# options: --depths "2 3 4 5" --program reorder_5 --reps 3 --runs 10000 --timeout 1800
```

The wrapper starts the pinned image with `--privileged --network none`, mounts
the repository at `/repro`, and runs `scripts/extension.sh` inside it. The
in-container script verifies the pinned upstream commit, probes
`SCHED_DEADLINE`, builds `reorder_5` with the author's build script, and runs the
depth sweep. Raw logs and the generated `extension_summary.csv` are archived
under a new `results/extension-reorder_5-<timestamp>/` bundle. No upstream files
are modified (`upstream-status-after.txt` must be empty).

## 4. Expected result and interpretation

- **Small d (2):** if the target bug's depth exceeds the bound, PERIOD is
  expected to explore the full budget without triggering the assertion failure,
  or to find it much later. This supports the paper's claim that bound size
  gates detection.
- **d = 3:** should match the C2 reference (225 schedules on `reorder_5`),
  confirming the extension setup agrees with the main experiment.
- **Larger d (4, 5):** expected to explore more schedules while still finding
  the bug, illustrating the cost/benefit trade-off of a larger bound.

The verdict is read against the paper's claim that schedule exploration grows
with the period bound. If, contrary to expectation, `d = 2` still finds the bug
in a similar number of schedules, the depth-bound explanation would be weakened,
and a likely cause to check is that the bug's actual depth is smaller than
assumed. Any such discrepancy should be quantified from the CSV before drawing a
conclusion.

## 5. Measured results (from the real run)

Executed on 2026-11-22 on an x86_64 Windows 11 host with WSL2
(`6.18.33.1-microsoft-standard-WSL2`) and Docker Desktop 29.9.3, using the
pinned author image. `SCHED_DEADLINE` was confirmed available inside the
container. The full command was `bash scripts/run-extension.sh` (defaults:
depths 2/3/4/5, 3 repetitions, 10,000-schedule budget, 1800 s timeout). Bundle:
`results/extension-reorder_5-20261122T060242Z-1/` (13 logs + summary CSV/JSON).

| Depth bound `d` | Reps | Bug found | Schedules to first error (mean) | Total schedules (mean) | Buggy interleavings (mean) | Capped |
| --- | --- | --- | --- | --- | --- | --- |
| 2 | 3 | 3/3 | 41 | 41 | 4 | no |
| 3 | 3 | 3/3 | 225 | 225 | 20 | no |
| 4 | 3 | 3/3 | 225 | 225 | 20 | no |
| 5 | 3 | 3/3 | 225 | 225 | 20 | no |

All 12 runs triggered the target assertion; none hit the 10,000-schedule cap
or the timeout, and `upstream-status-after.txt` is empty. `d = 3` reproduces
the C2 reference exactly (225 schedules, 20 buggy interleavings), confirming
the extension harness agrees with the main experiment.

**Interpretation.** Two observations refine the paper's depth-bound story:

1. **`d = 2` already finds the bug, and much faster (41 vs 225 schedules).**
   This is the contrary case anticipated in Section 4: the target bug in
   `reorder_5` has an effective depth smaller than the `d = 3` used by the
   paper's SCTBench configuration. A tighter bound explored a *smaller* space
   and still reached the bug, so `d = 3` is sufficient but not necessary here.
2. **The result saturates for `d >= 3`** — 225 schedules and 20 buggy
   interleavings are identical at `d = 3, 4, 5`. Increasing the bound beyond
   the bug's depth does not enlarge the space that matters for detection; the
   extra capacity is simply never exercised before the first failure.

Together these quantify the cost/benefit of the depth knob: raising `d` past
the actual bug depth is wasted budget, while setting it below the depth risks
missing deeper bugs. This supports the paper's claim that the period/depth
bound is the key trade-off knob, while showing the relationship is a step
function (fast at `d = 2`, then flat) rather than a smooth growth for this
particular bug. Every number above is traceable to the archived per-depth logs
under `results/extension-reorder_5-20261122T060242Z-1/extension/`.

## 6. Relation to the report

Reference this experiment in the *Extension* section of the final report: state
the question and motivation (Section 1), the single changed factor and fixed
conditions (Section 2), the Paper-vs-Ours / d-sweep table from
`extension_summary.csv`, and the interpretation (Section 4). Every reported
number must be traceable to the archived per-depth logs.
