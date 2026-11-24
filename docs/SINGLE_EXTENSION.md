# Extension: one unified experiment, four Critical-Analysis points

This is **one extension experiment** — a single protocol with a single bundle —
that was designed so that the same runs provide evidence for all four points in
the presentation brief: **Scalability, Compatibility, Security, Reproducibility**.

It is deliberately **not** four separate sub-experiments (CA1/CA2/CA3/CA4) and
it does **not** contain RQ1–RQ4 — those remain independent research questions in
[`RQ_ANALYSIS.md`](RQ_ANALYSIS.md). It is also distinct from the earlier
single-factor depth-bound study in [`EXTENSION.md`](EXTENSION.md).

## 1. Design: one matrix, four readings

A fixed set of five programs is run with PERIOD under one protocol; the only
deliberate axis of variation is the **CPU-core budget** on one mid-size program.
Everything else (image, commit, scheduler, budget 3,000, timeout 180 s, toolchain)
is held fixed.

| Program | Era | Core settings | Which point it evidences |
| --- | --- | --- | --- |
| `CVE-2009-3547` | 2009 | all | Compatibility |
| `CVE-2011-2183` | 2011 | all | Compatibility |
| `CVE-2016-1972` | 2016 | all | Compatibility |
| `reorder_5` | SCTBench | all | Scalability baseline |
| `reorder_10` | SCTBench | all / 1 core / 4 cores | Scalability |

Two passive observations are attached to the **same** runs, requiring no extra
experiment:

- the whole matrix runs in a `--privileged` container, while a second, otherwise
  identical, container is started **without** privileges solely to read the
  capability set — giving the **Security** reading;
- every run records the pinned commit / kernel / toolchain fingerprint, and the
  same invocation performs a fresh clone plus the offline verifier — giving the
  **Reproducibility** reading.

Run with `make single` on an x86_64 Linux/WSL2 host with Docker. Bundle:
`results/single-20261124T153949Z-1472/` (7 run logs + environment, security,
reproducibility logs, `single_runs.csv`, `single_security.csv`,
`single_summary.json`). All numbers below come from that one bundle.

## 2. Measured results from the one experiment

### Scalability — from the `reorder_10` core axis

| Run | Cores | Schedules explored | Bug found |
| --- | --- | ---: | --- |
| reorder_10 all | 16 | 1,260 (hit 180 s timeout) | yes |
| reorder_10 cpus=0 | 1 | 156 | **no** |
| reorder_10 cpus=0-3 | 4 | 157 | **no** |

With 16 cores the run reaches the bug and explores 1,260 schedules within the
budget; with 1 or 4 cores the same program stalls at ~156 schedules in the same
180 s and never exposes the bug. The scheduler's throughput depends on real
parallelism — a concrete scalability caveat. (`reorder_5` on all cores: 225
schedules, 30.5 s, bug found.)

### Compatibility — from the three legacy CVE runs

| Program | Era | Schedules to bug | Bug found | Time |
| --- | --- | ---: | --- | ---: |
| CVE-2009-3547 | 2009 | 6 | yes | 7.0 s |
| CVE-2011-2183 | 2011 | 226 | yes | — |
| CVE-2016-1972 | 2016 | 55 | yes | 7.9 s |

All three decade-old C programs were compiled **unchanged** with the pinned
clang 10 / gcc 7.5 toolchain and ran on kernel `6.18.33.1-microsoft-standard-WSL2`;
all exposed their bug. The artifact ships no ARM image, so cross-architecture
behaviour remains untested.

### Security — from the privilege context of the same protocol

| Context | CapEff | CAP_SYS_NICE (bit 23) | `sched_setattr` |
| --- | --- | --- | --- |
| privileged (ran the matrix) | `000001ffffffffff` | 1 | `PROBE_OK` |
| unprivileged (same image) | `00000000a80425fb` | 0 | would fail `EPERM` |

The experiment that found the bugs **needed a privileged container**. Granting
`CAP_SYS_NICE` (normally via `--privileged`) crosses the normal container
isolation boundary — a genuine trust-boundary cost, mitigated by using a
disposable, isolated VM and trusted workloads only.

### Reproducibility — recorded by the same invocation

| Check | Result |
| --- | --- |
| Upstream commit == `b6f72a7` | yes |
| Fresh `git clone` of pinned source | OK, same commit |
| Offline verifier (`verify-results.py`) | OK |
| Environment | x86_64, kernel 6.18.33.1, clang 10.0.0, gcc 7.5.0, Python 3.6.9 |

Pinned image digest + commit + `make verify` let another group re-run and
cross-check every archived log offline. Reimplementing PERIOD from scratch is
the harder part (LLVM IR instrumentation + SVF + `SCHED_DEADLINE`).

## 3. Bottom line

One experiment, one bundle, four conclusions:

- **Scalability**: works with spare cores; collapses on 1–4 cores.
- **Compatibility**: legacy 2009–2016 C code runs unmodified on a modern kernel.
- **Security**: effective use requires `CAP_SYS_NICE` — a privilege cost.
- **Reproducibility**: pinned commit/digest and offline verification make it
  re-runnable, though not trivially re-implementable.

Evidence files: `single_runs.csv` (7 runs), `single_security.csv` (2 contexts),
`single_repro.json`, and the raw logs under `results/single-20261124T153949Z-1472/`.
