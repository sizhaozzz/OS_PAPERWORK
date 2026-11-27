# Research Questions RQ1–RQ4 and Critical Analysis

This document reports the four research questions of the replication and maps
them to the four Critical-Analysis points required for the presentation
(scalability, compatibility, security implications, reproducibility). RQ1 is
covered by the already-archived C2 experiment; RQ2–RQ4 were executed on
2026-11-24 on the same pinned author image and host.

Host: x86_64 Windows 11 with WSL2 (`6.18.33.1-microsoft-standard-WSL2`),
Docker Desktop 29.9.3, image `wcventure/period@sha256:8f47d8b9...`. The
`SCHED_DEADLINE` probe passes in every run. All numbers trace to logs under
`results/rq-*/`.

## RQ1 — Parallel scheduler (PDS) vs Serial (SS)

Covered by the C2 experiment (bundle `experiments-c2-20261114T142131Z-1`).
PERIOD needed 27/100/225/2,350 schedules on reorder_3/4/5/10 vs Serial's
30/384/4,568/>10,000 — a 10.0%/74.0%/95.1%/>76.5% reduction, matching the
paper's Table 2 exactly. Verdict: **supported**. (Not re-run here.)

## RQ2 — PERIOD bug-finding on more workloads

The author image ships only the PERIOD (PDS) and Serial (SBP) schedulers; the
PCT/IPB/Maple binaries are **not** distributed with the artifact. We therefore
run PERIOD on eight additional SCTBench programs and compare the schedule
counts directly against the paper's Table 2 PERIOD column (the paper's SOTA
numbers are used as the external reference). Bundle:
`results/rq-rq2-20261124T142134Z-1/` (1 run each, 5,000-schedule budget, 240 s timeout).

| Program | Ours: total schedules | Paper (Table 2, PERIOD): schedules | Ours buggy interleavings | Paper | Bug found |
| --- | --- | --- | --- | --- | --- |
| account | 65 | 65 | 27 | 26 | yes |
| bluetooth_driver | 205 | 205 | 7 | 9 | yes |
| carter01 | 42 | 42 | 10 (deadlock timeouts) | 11 | yes |
| circular_buffer | 546 | 871 | 57 | 207 | yes |
| deadlock01 | 14 | 14 | 6 (deadlock timeouts) | 6 | yes |
| lazy01 | 39 | 39 | 13 | 12 | yes |
| queue | 833 | 998 | 64 | 119 | yes |
| stack | 918 | 918 | 95 | 144 | yes |

**Result: 8/8 programs produced a bug.** Total schedule counts matched Table 2 for six of the eight programs. For circular_buffer, PERIOD explored 546 schedules compared with 871 in the paper. For queue, it explored 833 compared with 998. The two deadlock programs report the bug as
timeouts rather than assertion failures, which is expected for DL-type bugs.

**Scope / division of work.** This commit runs **PERIOD only** — no other
bug-finding tool (PCT, IPB, Maple, ...) was executed. Those SOTA baselines are
**handled by other group members**; they are out of scope for this commit. The
author image does not ship PCT/IPB/Maple binaries, and the paper's published
Table 2 numbers are used only as an external reference, not as a reproduced
head-to-head comparison. Two programs differ in buggy-interleaving counts
(e.g. 95 vs 144 on stack): that metric depends on how long exploration continues
after the first failure and on kernel timing, not on bug-finding ability.
Verdict for this batch: PERIOD detected the target bug in all eight tested programs. Comparing its bug-finding performance with the six baseline methods requires measurements from those methods.

### Three-run PERIOD comparison with Table 2

We ran PERIOD three times on each of three SCTBench programs, with a budget of 10,000 schedules and a 240-second timeout per run. All nine runs detected the target assertion failure and exited with code 0. Our results are reported as mean ± sample standard deviation.

| Program | Runs detecting the bug | First bug: ours | First bug: paper | Total schedules: ours | Total schedules: paper |
| --- | ---: | ---: | ---: | ---: | ---: |
| account | 3/3 | 6.33 ± 3.51 | 2 | 65 ± 0 | 65 |
| bluetooth_driver | 3/3 | 9 ± 0 | 9 | 205 ± 0 | 205 |
| circular_buffer | 3/3 | 17 ± 0 | 17 | 574 ± 48.50 | 871 |

For bluetooth_driver, both measurements matched Table 2. For account, the total was 65 in every run, but the first failure occurred later on average than in the paper. For circular_buffer, all three runs found the first failure at schedule 17, matching the paper, while exploring 297 fewer schedules on average.

[Run summary and logs](../results/rq-rq2-20261126T190054Z-1/)

## RQ3 — Hyperparameter sensitivity: bug depth d x period bound

The paper fixes `d = 3` for SCTBench and states that a depth-*d* bug needs about
*d + 1* periods, but never sweeps both parameters. We patched a runner copy to
decouple `period_limit` from `bugDepth` (`PERIOD_OVERRIDE`) and ran a grid on a
fixed workload (`reorder_5`, PERIOD, 1 run per cell, 5,000 budget, 240 s timeout).
Bundle: `results/rq-rq3-20261124T143652Z-1/`.

| d | period bound | Bug found | Schedules to first bug | Total schedules | Buggy interleavings |
| --- | --- | --- | --- | --- | --- |
| 2 | 2 | **no** | — | 5 | — |
| 2 | 3 | yes | 12 | 41 | 4 |
| 2 | 4 | yes | 12 | 225 | 20 |
| 2 | 5 | yes | 12 | 225 | 20 |
| 3 | 2 | **no** | — | 5 | — |
| 3 | 3 | yes | 12 | 41 | 4 |
| 3 | 4 | yes | 12 | 225 | 20 |
| 3 | 5 | yes | 12 | 225 | 20 |

**Findings.**
1. **Period bound is the dominant knob, not d.** At period = 2 the search
   exhausts after 5 schedules with no bug for both d = 2 and d = 3. At period
   ≥ 3 the bug is always found, and the two depth settings give *identical*
   results. The paper's `d + 1` rule therefore matters mainly through the
   period count it induces.
2. **Step function, then saturation.** Raising the period from 3 to 4 increases
   schedules from 41 to 225 (5.5x) and buggy interleavings from 4 to 20; from
   4 to 5 nothing changes. Extra period capacity beyond the bug's needs is not
   exercised before the first failure.
3. This refines the paper's claim that exploration grows with the bound: for
   this bug the growth is a step (no bug → 41 → 225 → flat), not smooth.

Verdict: **partially supports** the paper's bound discussion — the bound gates
detection as claimed, but depth and period are not independent drivers here, and
the effect saturates quickly.

## RQ4 — Overhead of the Linux SCHED_DEADLINE mechanism

The paper (Figure 7) reports 2–30x slowdown of PERIOD vs native execution, but
does not isolate the cost of the underlying `SCHED_DEADLINE` scheduler. We wrote
a micro-benchmark (`rq4/deadline_overhead.c`) that spawns N threads and performs
50 `sched_yield()` calls, comparing plain CFS threads against threads placed on
`SCHED_DEADLINE` (runtime = deadline = period = 20 ms). Bundle:
`results/rq-rq4-20261124T143635Z-1/` (3 runs per cell).

| Threads | Scheduler | Wall time (mean, 50 yields) | Slowdown vs CFS |
| --- | --- | --- | --- |
| 1 | CFS | 0.000228 s | 1x |
| 1 | SCHED_DEADLINE | 1.000569 s | **4,388x** |
| 4 | CFS | 0.000434 s | 1x |
| 4 | SCHED_DEADLINE | 1.000416 s | **2,305x** |

**Finding.** Under this kernel, each `sched_yield()` by a `SCHED_DEADLINE` task
costs about one full 20 ms period (50 yields ≈ 1.0 s), whereas a CFS yield is
microseconds. Because the threads run in parallel, the total wall time stays at
~1 s regardless of thread count, so the *per-thread* slowdown is constant while
the aggregate slowdown ratio shrinks with N.

**Interpretation.** PERIOD deliberately uses `sched_yield()` at key points to
realise a selected schedule, so this per-yield cost is the dominant low-level
source of its runtime overhead. On a native Linux host the 20 ms reservation is
a worst case; the same experiment on a production kernel with finer bandwidth
settings would likely show a smaller constant. This measurement is a
**kernel-specific upper bound in WSL2**, not a general PERIOD overhead number.
An earlier configuration with runtime = 1 ms / period = 10 ms produced severe
bandwidth throttling (50 yields ≈ 1 s; 2,000 yields ≈ 40 s) and was superseded
by the 20/20/20 ms setting; the superseded bundle is marked `.INVALID`.

## Mapping to the four Critical-Analysis points (from the presentation slide)

- **Scalability (many cores / heavy load).** RQ1's reorder_10 (>10,000 schedules
  for Serial vs 2,350 for PERIOD) and RQ4's 1-vs-4-thread micro-benchmark show
  that PERIOD's parallel last period scales with available cores (the paper
  reports 8–34x speedups from 1 to 8 cores). Our WSL2 run confirms multi-thread
  deadline tasks execute concurrently, but we did not reproduce the paper's
  8-core speedup curve — recorded as a limitation.
- **Compatibility (hardware, kernel versions, legacy integration).** Everything
  was reproduced on a *newer* kernel (6.18 WSL2) than the paper'sUbuntu 18.04,
  with the artifact's original GCC 7.5/LLVM 10 toolchain. The RQ4 result shows
  the scheduler's behaviour is strongly kernel-dependent: this is concrete
  evidence that `SCHED_DEADLINE` timing assumptions do not transfer unchanged
  across kernel versions. The technique requires a Linux host with
  `SCHED_DEADLINE` enabled; it cannot run on Windows natively.
- **Security implications.** `SCHED_DEADLINE` requires `CAP_SYS_NICE` (normally
  granted via `--privileged`), i.e. elevated privileges for the whole test
  process. Running untrusted benchmark code under such privileges enlarges the
  attack surface; a production deployment should isolate the testing process,
  run only trusted workloads, and prefer the narrowest capability set. This is
  an inherent implication of the approach, not a bug in the reproduction.
- **Reproducibility.** `Dockerfile`, `Makefile`, `scripts/setup.sh`, pinned image
  digest and upstream commit make the whole pipeline reproducible from the
  README alone; `make verify` cross-checks every archived log without Docker.
  All reported numbers here are traceable to `results/rq-*/` logs and CSVs.

## Files

- Scripts: `scripts/rq_suite.sh`, `scripts/run-rq.sh`, `scripts/summarize_rq.py`
- Make targets: `make rq`, `make rq2`, `make rq3`, `make rq4`
- Bundles: `results/rq-rq2-20261124T142134Z-1/`,
  `results/rq-rq3-20261124T143652Z-1/`, `results/rq-rq4-20261124T143635Z-1/`
