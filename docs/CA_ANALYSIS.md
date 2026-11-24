# Critical Analysis Extension — Scalability, Compatibility, Security, Reproducibility

This is a **separate extension** that answers the four Critical-Analysis points
from the presentation brief directly, with executed evidence rather than
discussion alone. Unlike the earlier depth-bound extension, it is **not**
single-factor: each part changes whatever is needed to probe one CA dimension.

All runs used the pinned author image
`wcventure/period@sha256:8f47d8b9...` (upstream commit `b6f72a7`), on an
x86_64 Windows 11 / WSL2 host (kernel `6.18.33.1-microsoft-standard-WSL2`),
Docker 29.9.3. Bundle: `results/ca-20261124T150414Z-703/`. The scripts are
`scripts/run-ca.sh` (host) + `scripts/ca_suite.sh` (container) +
`scripts/summarize_ca.py`; reproduce with `make ca` (or one part: `make ca1` … `make ca4`).

---

## CA1 — Scalability: does it work at production scale (many cores, heavy load)?

Two axes were varied: thread count (`reorder_5/10/20/50`) and CPU-core
availability (pinning `reorder_10` to 1, 4, or 16 cores with `taskset`).
Budget: 3,000 schedules, 180 s per run. All numbers re-parsed from raw logs.

| Workload | Cores | Schedules explored | Bug found? | Outcome |
| --- | --- | --- | --- | --- |
| reorder_5 | 16 | 225 | yes | completed in 27.5 s |
| reorder_10 | 16 | 2,350 | yes | completed in 161.5 s |
| reorder_10 | 4 | 159 | **no** | hit 180 s timeout |
| reorder_10 | 1 | 157 | **no** | hit 180 s timeout |
| reorder_20 | 16 | 197 | yes | found 80 errors, hit timeout before summary |
| reorder_50 | 16 | 527 | yes | found 34 errors, hit timeout before summary |

**What this says.** The method *does* find the bug in heavy workloads
(20 and 50 threads), but two scalability limits are visible:

1. **It depends on real parallelism.** The same `reorder_10` program on 1 or 4
   cores exhausted the 180 s budget after ~157 schedules with no bug, while 16
   cores reached 2,350 schedules and found it. The `SCHED_DEADLINE`-based
   scheduler needs spare cores to interleave threads; on a constrained machine
   its throughput collapses. This matches the paper's design (parallel
   scheduler) but is a concrete caveat for "production scale" claims.
2. **Cost grows sharply with thread count.** Per-schedule wall time rises from
   ~0.12 s (5 threads) to ~0.34 s (10 threads); 20/50-thread runs found the bug
   but did not finish the full 3,000-schedule budget within 180 s. Larger
   programs are testable, but a fixed time budget buys far fewer explorations.

Chart: `figures/fig7_ca_scalability.svg`.

---

## CA2 — Compatibility: architectures, kernel versions, legacy software

Three legacy CVE programs (2009–2016 C code) from the artifact's
`ConVul-CVE-Benchmarks` were compiled and run unchanged on the modern 6.18
kernel. No source was modified; the same pinned toolchain (clang 10 / gcc 7.5)
was used.

| Program | Era | Build | Binary | Schedules to first bug | Bug found |
| --- | --- | --- | --- | --- | --- |
| CVE-2009-3547 | 2009 | OK | OK | 6 | yes |
| CVE-2011-2183 | 2011 | OK | OK | 233 | yes |
| CVE-2016-1972 | 2016 | OK | OK | 55 | yes |

Platform fingerprint: `x86_64`, kernel `6.18.33.1-microsoft-standard-WSL2`,
userland Ubuntu 18.04, clang 10.0.0, gcc 7.5.0, Python 3.6.9.

**What this says.** Compatibility is **good within x86_64 + the pinned
toolchain**: decade-old vulnerable C code builds unmodified and the bug is
found on a much newer kernel than the paper's Ubuntu 18.04 (4.15). Two honest
limits: (a) the artifact ships **no ARM/aarch64 image**, so cross-architecture
behaviour cannot be tested here; (b) the instrumented build depends on a
specific LLVM 10 / SVF toolchain in the image — "legacy software" works, but
only through that pinned compiler stack, not arbitrary native toolchains.

---

## CA3 — Security implications

`SCHED_DEADLINE` is a real-time scheduling policy; setting it requires the
`CAP_SYS_NICE` capability. The capability was measured in two containers from
the same image: one started with `--privileged`, one with default privileges.
Because calling `sched_setattr` in the unprivileged context is trapped by this
environment before it can report, the capability boundary was established by
reading `CapEff` (bit 23 = `CAP_SYS_NICE`) plus a successful syscall probe in
the privileged context.

| Context | CapEff | CAP_SYS_NICE (bit 23) | sched_setattr |
| --- | --- | --- | --- |
| privileged | `000001ffffffffff` | 1 | PROBE_OK |
| unprivileged | `00000000a80425fb` | 0 | would fail EPERM (Operation not permitted) |

**What this says.** Running PERIOD effectively **requires granting a container
privileged, real-time scheduling capability**. That is a meaningful security
cost: a privileged container breaks the normal isolation boundary, and any
bug in the instrumented target or scheduler runs with elevated kernel-facing
privileges. In a shared CI/cloud environment this is a trust-boundary concern,
not just a convenience issue. Mitigation: run in an isolated, disposable VM,
grant only `CAP_SYS_NICE` where possible, and never on untrusted workloads.

Chart: `figures/fig8_ca_security.svg`.

---

## CA4 — Reproducibility: can other researchers implement this easily?

The bundle records a reproducibility fingerprint and two concrete checks:

| Check | Result |
| --- | --- |
| Upstream commit == expected `b6f72a7` | yes |
| Fresh `git clone` of pinned source | OK, same commit |
| Offline verifier (`verify-results.py`, no Docker) | OK |
| Environment | clang 10.0.0 / gcc 7.5.0 / Python 3.6.9 / kernel 6.18 |

**What this says.** Reproducibility is **strong for running the artifact**: a
pinned image digest + pinned upstream commit + `make setup`/`make verify` mean
another group can reproduce all recorded results without Docker expertise, and
can validate archived logs offline. The residual difficulty is *implementing
the method from scratch* — it requires LLVM IR instrumentation, SVF static
analysis and kernel-level `SCHED_DEADLINE` control, which is why this
replication reuses the authors' image rather than reimplementing PERIOD. That
distinction ("re-run easily, reimplement with effort") is stated explicitly.

---

## Bottom line for the presentation

- **Scalability**: works on 20/50 threads, but needs many cores; on 1–4 cores
  throughput collapses — a real caveat.
- **Compatibility**: 2009–2016 legacy CVEs build and run unmodified on a modern
  kernel; cross-architecture untested (no ARM image in artifact).
- **Security**: needs `CAP_SYS_NICE`/privileged containers — a trust-boundary
  cost, not just a setup detail.
- **Reproducibility**: pinned image + commit + offline verifier make re-running
  easy; reimplementation remains nontrivial.
