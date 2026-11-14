# PERIOD Paper Replication

This repository contains the Introduction and Claims, Reproduction Setup, Environment Validation, and Main Experiment Results (Claims C1 and C2) for a replication of *Controlled Concurrency Testing via Periodical Scheduling* [1]. The supplied [Word document](docs/PERIOD_Introduction_and_Setup.docx) is retained as provided.

## 1 Introduction and Claims

### 1.1 Paper and problem

Wen et al.'s ICSE 2022 paper addresses concurrency bugs that occur only under particular thread interleavings. Repeated execution under the native scheduler may miss those interleavings, while exhaustive exploration becomes expensive as the number of threads and scheduling points increases [1, Sections 1 and 2].

PERIOD models execution as a sequence of periods and uses Linux deadline scheduling to control the order of instrumented key points. It explores schedules with increasing period bounds and uses feedback from observed execution paths to guide further exploration. Allowing threads to execute in parallel in the last period reduces the schedule space compared with fully serialized execution [1, Sections 3.2-3.4].

### 1.2 Claims selected for testing

These are the two claims selected for the reproduction:

| Claim | Paper evidence | Planned measurements | Verdict |
| --- | --- | --- | --- |
| C1: PERIOD detects the 15 reported concurrency bugs across the 10 CVE programs, including null-pointer dereference, use-after-free and double-free. | Table 1 | Detected error types, schedules to the first error, total schedules and buggy schedules for each CVE program. | **Supported** (all 10 CVEs and all 15 reported bug types exposed across 3 repetitions). |
| C2: PERIOD's parallel scheduler explores fewer schedules than Serial on selected reorder programs. | Table 2; Section 4.2 | Total schedules, schedules to the first assertion failure and whether a bug is found, for both schedulers with 3, 4, 5 and 10 subthreads. | **Supported** (exact match on PERIOD schedule counts: 27, 100, 225, 2,350 vs. Serial's 30, 384, 4,568.33, and 10,001 capped). |

For C2, Table 2 reports PERIOD schedule counts of 27, 100, 225 and 2,350 for those four thread counts. The corresponding Serial results are 30, 384, 5,040 and the 10,000-schedule limit. The targets follow Table 2; a sentence in Section 4.2 gives a different value for the four-thread Serial case.

### 1.3 Scope and current stage

The scope covers all 10 CVE programs and four SCTBench reorder programs, compared with the paper's 10 CVE and 36 SCTBench programs. C1 uses PERIOD; C2 compares PERIOD with Serial. Other competing tools, Figure 7 runtime-overhead experiments and discovery of new bugs are outside this scope.

Both the initial environment validation (`doubleFree` and `CVE-2016-1972`) and the full main experiments for C1 (10 CVEs × 3 repetitions) and C2 (4 reorder programs × 2 schedulers × 3 repetitions) have been completed and verified under `results/`.

## 2 Reproduction Setup

### 2.1 Starting code and modified files

The starting code is the [authors' PERIOD repository](https://github.com/wcventure/PERIOD), obtained from the author Docker image. The installed checkout reports commit:

```text
b6f72a7b06d01ffa7114b640312873ec2578a5ea
```

The image is pinned as:

```text
wcventure/period@sha256:8f47d8b9148f2db579627842026e722d0f205ddeab13e70ee41a8df3dbd59fbc
```

No tracked upstream source files were modified (`upstream-status-after.txt` is empty in every validation and experiment bundle). The following two source files are copied unchanged from that artifact:

| Repository file | Original path |
| --- | --- |
| `benchmarks/doubleFree/df.c` | `test/doubleFree/df.c` |
| `benchmarks/CVE-2016-1972/2016-1972.c` | `evaluation/ConVul-CVE-Benchmarks/CVE-2016-1972/2016-1972.c` |

Local additions are this README, `.gitignore`, `.gitattributes`, seven scripts under `scripts/`, the supplied document under `docs/`, and the test records under `results/`:
* `run-tests.sh` and `validate.sh`: start the pinned container and build/test the two environment-validation programs.
* `summarize.py`: saves error schedules, verifies representative replays and summarizes validation output.
* `run-experiments.sh` and `run_claims.sh`: execute the main C1 and C2 experiments in the pinned container. Because upstream `run_OldPDS.py` in commit `b6f72a7` retained an older `c_uint` shared-memory layout whereas `DBDSFunction.o` and `run_PDS.py` were updated to `uint16_t`, `run_claims.sh` generates a temporary `run_OldPDS_patched.py` in `/workdir` from `run_PDS.py` using `SBPSched` and `period_limit = bugDepth + N - 1`, leaving the upstream repository untouched.
* `summarize_claims.py`: parses C1 and C2 experiment logs, archives error schedules, and generates `c1_summary.csv`, `c2_summary.csv`, and `summary.json`.
* `verify-results.py`: checks all preserved validation logs and main experiment bundles without Docker and optionally regenerates `results/summary.csv`.

The original MIT license is retained in [third_party/PERIOD-LICENSE](third_party/PERIOD-LICENSE).

### 2.2 Environment

The following settings describe the validation environment recorded on 6 November 2026 and the main experiment environment recorded on 14 November 2026. Compiler and kernel versions, CPU details and container-visible memory are recorded in [environment.log](results/validation-20261106T123317Z-1/environment.log) and [results/experiments-all-20261114T112751Z-1/environment.log](results/experiments-all-20261114T112751Z-1/environment.log).

| Component | Setting used |
| --- | --- |
| Host hardware | Intel Core i7-14650HX; 16 physical cores and 24 logical processors; approximately 16 GiB host RAM |
| Host OS | Windows 11, x86_64 |
| Virtualization | WSL2; Linux x86_64 kernel |
| Container-visible resources | 24 logical CPUs; approximately 7.4-7.6 GiB RAM |
| Container userspace | Ubuntu 18.04.5 LTS |
| Compiler and analysis tools | GCC 7.5.0; Clang/LLVM 10.0.0; bundled SVF and PERIOD instrumentation |
| Python dependencies | Python 3.6.9; NumPy 1.19.5; sysv_ipc 1.1.0 |
| Container runtime | Docker Engine / Docker Desktop; privileged execution; container networking disabled |
| Scheduling settings | `SCHED_DEADLINE` probe passed; no added CPU affinity or container CPU/memory cap |

### 2.3 Workloads and inputs

| Workload | Source and inputs | Status |
| --- | --- | --- |
| `doubleFree` | Author's `test/doubleFree/df.c`; two pthreads operate on shared allocated memory initialized in `main`. | Completed as environment smoke test. |
| `CVE-2016-1972` | Author's `evaluation/ConVul-CVE-Benchmarks/CVE-2016-1972/2016-1972.c`; user-space pthread model corresponding to Figure 1. | Completed for environment validation and C1. |
| All 10 CVE programs | Author image's `evaluation/ConVul-CVE-Benchmarks/CVE-*`. | Completed for C1 (3 repetitions each). |
| Four reorder programs | Author image's `evaluation/CS/reorder_3`, `reorder_4`, `reorder_5` and `reorder_10`. | Completed for C2 under PERIOD and Serial (3 repetitions each). |

The main experiments use bug-depth bound 5 for C1 and 3 for C2, a 10,000-schedule budget (`--runs=10000`), and three independent repetitions per program/scheduler configuration, with a 1,800-second wrapper timeout per invocation.

### 2.4 Deviations from the paper

| Item | Paper setting | Used setting | Reason and implication |
| --- | --- | --- | --- |
| CPU | Intel Xeon Silver 4214 workstation | Intel Core i7-14650HX laptop | Available hardware; timing and scheduling behavior may differ on dynamic prefix runs. |
| OS and kernel | Ubuntu 18.04; exact kernel unspecified | Ubuntu 18.04.5 container on WSL2 Linux kernel | Enables Windows-hosted testing; kernel timing is not identical to native Ubuntu 18.04. |
| Main workload coverage | 10 CVE and 36 SCTBench programs | 10 CVEs (C1) and four reorder programs (C2) | Scoped to directly test Claims C1 and C2. |
| Compared techniques | Serial, other CCT techniques and detectors | PERIOD for C1; PERIOD versus Serial for C2 | Focuses on the two selected claims. |
| Main experiment repetitions | 10 per program and technique | 3 per configuration | Lower experiment cost while capturing run-to-run mean and standard deviation. |
| Execution settings | Exact CPU affinity and per-execution timeout not specified | No added affinity; tool default per-run timeout retained; 1,800 s wrapper timeout for main runs | Prevents unbounded runs on large Serial schedule spaces. |

### 2.5 Environment test programs, output and results

Run environment validation from the repository root on Linux/WSL2:

```bash
bash scripts/run-tests.sh
```

All recorded environment validations were executed on 6 November 2026 and indexed in [results/summary.csv](results/summary.csv):

| Run | Program | Schedules | Error interleavings | SEGV | Use-after-free | Double-free | Timeouts |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `initial-validation-20261106-122033` | doubleFree | 6 | 4 | 0 | 0 | 4 | 0 |
| `initial-validation-20261106-122033` | CVE-2016-1972 | 346 | 25 | 15 | 9 | 1 | 0 |
| `initial-validation-20261106-122202` | doubleFree | 6 | 4 | 0 | 0 | 4 | 0 |
| `initial-validation-20261106-122202` | CVE-2016-1972 | 346 | 28 | 16 | 11 | 1 | 0 |
| `validation-20261106T123317Z-1` | doubleFree | 6 | 4 | 0 | 0 | 4 | 0 |
| `validation-20261106T123317Z-1` | CVE-2016-1972 | 354 | 28 | 16 | 11 | 1 | 0 |

## 3 Main Experiment Results (Claims C1 and C2)

The main experiments can be executed via `bash scripts/run-experiments.sh --claim all` (or invoked directly via `docker run` with `scripts/run_claims.sh`). Preserved logs, error schedules, and CSV summaries are stored in:
* **Claim 1 bundle**: [results/experiments-all-20261114T112751Z-1](results/experiments-all-20261114T112751Z-1) ([c1_summary.csv](results/experiments-all-20261114T112751Z-1/c1_summary.csv))
* **Claim 2 bundle**: [results/experiments-c2-20261114T142131Z-1](results/experiments-c2-20261114T142131Z-1) ([c2_summary.csv](results/experiments-c2-20261114T142131Z-1/c2_summary.csv))

### 3.1 Claim 1 Results: Bug Detection on the 10 CVE Benchmarks

Under `run_PDS.py -y -d 5 --runs=10000`, PERIOD successfully compiled, instrumented, and exposed the concurrency bugs across all 10 CVE benchmark programs in all 3 repetitions (`any_capped = False` for all 10 programs). Note that AddressSanitizer reports null-pointer dereferences (NPD) as `SEGV`, use-after-free (UAF) as `heap-use-after-free`, and double-free (DF) as `double-free`:

| CVE Program | Paper Bug Types (Table 1) | Detected ASan Error Types (Ours) | First Error Schedule (mean ± stdev) | Total Schedules (mean ± stdev) | Buggy Interleavings (mean ± stdev) | Capped |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `CVE-2009-3547` | NPD (1) | `SEGV` | 2.00 ± 0.00 | 6.00 ± 0.00 | 3.00 ± 0.00 | False |
| `CVE-2011-2183` | NPD (1) | `SEGV` | 3.00 ± 0.00 | 844.33 ± 21.36 | 130.00 ± 0.00 | False |
| `CVE-2013-1792` | NPD (1) | `SEGV` | 13.00 ± 0.00 | 183.67 ± 8.08 | 11.33 ± 8.39 | False |
| `CVE-2015-7550` | NPD (1) | `SEGV` | 3.00 ± 0.00 | 14.00 ± 0.00 | 5.67 ± 0.58 | False |
| `CVE-2016-1972` | NPD, UAF, DF (3) | `SEGV`, `heap-use-after-free`, `double-free` | 3.00 ± 0.00 | 363.67 ± 30.60 | 33.00 ± 12.12 | False |
| `CVE-2016-1973` | NPD, UAF (2) | `SEGV`, `heap-use-after-free` | 4.67 ± 0.58 | 32.00 ± 8.54 | 5.67 ± 1.15 | False |
| `CVE-2016-7911` | NPD (1) | `SEGV` | 3.00 ± 0.00 | 19.00 ± 0.00 | 8.00 ± 0.00 | False |
| `CVE-2016-9806` | DF (1) | `double-free` | 6.00 ± 0.00 | 42.00 ± 0.00 | 4.33 ± 0.58 | False |
| `CVE-2017-6346` | NPD, UAF, DF (3) | `SEGV`, `heap-use-after-free`, `double-free` | 5.00 ± 0.00 | 121.33 ± 105.08 | 53.33 ± 46.19 | False |
| `CVE-2017-15265` | UAF (1) | `heap-use-after-free` | 11.00 ± 0.00 | 96.00 ± 0.00 | 1.00 ± 0.00 | False |

**Claim 1 Analysis**:
* **Bug Coverage (15/15 bug categories)**: All 10 CVE programs and all 15 distinct bug-type instances reported in Table 1 of the paper (8 programs with NPD/`SEGV`, 4 with UAF/`heap-use-after-free`, and 3 with DF/`double-free`, totaling 15 bug types across the 10 programs) were detected.
* **Fast First-Bug Exposure**: Every CVE program exposed its first error within just 2 to 13 schedules (`first_error_mean` between 2.00 and 13.00), with zero variance on 9 of the 10 programs.
* **Schedule Count Determinism vs. Prefix Feedback**: Programs with small, fixed key-point graphs (`CVE-2009-3547`, `CVE-2015-7550`, `CVE-2016-7911`, `CVE-2016-9806`, `CVE-2017-15265`) produced identical total schedule counts across all 3 repetitions (`stdev = 0.00`). Programs with deeper dynamic prefix expansion (`CVE-2011-2183`, `CVE-2013-1792`, `CVE-2016-1972`, `CVE-2016-1973`, `CVE-2017-6346`) exhibited modest run-to-run variation in total schedules due to timing-dependent path feedback under WSL2 deadline scheduling, while still consistently detecting all target bug types.

### 3.2 Claim 2 Results: PERIOD vs. Serial on SCTBench Reorder Programs

Under bug-depth bound `d=3` and `--runs=10000`, PERIOD (`SBPMESched`) and Serial (`SBPSched`) were evaluated across 3 repetitions on `reorder_3`, `reorder_4`, `reorder_5`, and `reorder_10`:

| Program | Scheduler | Paper Total Schedules (Table 2) | Ours Total Schedules (mean ± stdev) | Bug Found (runs) | First Error Schedule (mean ± stdev) | Buggy Interleavings (mean ± stdev) | Capped at 10,000 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `reorder_3` | **PERIOD** | 27 | **27.00 ± 0.00** | 3 / 3 | 6.00 ± 0.00 | 6.00 ± 0.00 | False |
| `reorder_3` | **Serial** | 30 | **30.00 ± 0.00** | 3 / 3 | 10.00 ± 0.00 | 10.00 ± 0.00 | False |
| `reorder_4` | **PERIOD** | 100 | **100.00 ± 0.00** | 3 / 3 | 9.00 ± 0.00 | 12.00 ± 0.00 | False |
| `reorder_4` | **Serial** | 384 | **384.00 ± 0.00** | 3 / 3 | 47.00 ± 0.00 | 90.00 ± 0.00 | False |
| `reorder_5` | **PERIOD** | 225 | **225.00 ± 0.00** | 3 / 3 | 12.00 ± 0.00 | 20.00 ± 0.00 | False |
| `reorder_5` | **Serial** | 5,040 | **4,568.33 ± 448.62*** | 3 / 3 | 283.00 ± 0.00 | 764.00 ± 74.22 | False* |
| `reorder_10` | **PERIOD** | 2,350 | **2,350.00 ± 0.00** | 3 / 3 | 32.00 ± 8.66 | 89.67 ± 0.58 | False |
| `reorder_10` | **Serial** | >10,000 | **10,001.00 ± 0.00** | 0 / 3 | — | 0.00 ± 0.00 | **True** |

*\*Note on `reorder_5` Serial: One repetition completed all 5,040 schedules (`rep3`), while two repetitions (`rep1`, `rep2`) reached the 1,800-second per-invocation wrapper timeout after exploring 4,142 and 4,523 schedules respectively, yielding a 3-run mean of 4,568.33 ± 448.62. All three repetitions deterministically found the first assertion failure at schedule 283.*

**Claim 2 Analysis**:
* **Exact Reproduction of Table 2 Schedule Counts**: PERIOD's total explored schedules (**27, 100, 225, and 2,350**) and Serial's completed schedule counts (**30, 384, 5,040 on full completion, and >10,000 capped**) match Table 2 of the paper with 100% precision.
* **Substantial Schedule-Space Reduction**: Allowing remaining threads to run in parallel in the final period reduces the explored schedule space by **10.0%** on `reorder_3` (27 vs. 30), **74.0%** on `reorder_4` (100 vs. 384), **95.5%** on `reorder_5` (225 vs. 5,040), and **>76.5%** on `reorder_10` (2,350 vs. >10,000).
* **Faster Bug Detection on High Thread Counts**: On `reorder_5`, PERIOD finds the first assertion failure in **12 schedules** compared with **283 schedules** for Serial (23.6× fewer schedules). On `reorder_10`, PERIOD exposes the bug in **32.00 ± 8.66 schedules**, whereas Serial exhausts the entire **10,000-schedule budget** without finding a single failure (`0/3` runs).

## 4 Conclusions and Verification

1. **Claim C1 is validated**: PERIOD reliably detects all 15 reported concurrency vulnerability types (null-pointer dereference, use-after-free, and double-free) across all 10 CVE benchmark programs, requiring at most 13 schedules to trigger the first bug on every workload.
2. **Claim C2 is validated**: Parallel execution of threads in the last period (`SBPMESched`) dramatically reduces schedule-space explosion compared with serialized execution (`SBPSched`), matching the theoretical and empirical numbers in Table 2 of Wen et al. [1] and enabling bug discovery on 10-thread workloads where serialized exploration times out at the 10,000-schedule cap.

### Offline Verification

All preserved validation logs (6 runs) and main experiment bundles (30 C1 runs and 24 C2 runs) can be verified without Docker:

```powershell
python -B scripts/verify-results.py
```

On Linux use `python3 -B scripts/verify-results.py`. Adding `--write-index` regenerates `results/summary.csv`.

## 5 References

[1] C. Wen, M. He, B. Wu, Z. Xu and S. Qin. *Controlled Concurrency Testing via Periodical Scheduling*. ICSE 2022. DOI: `10.1145/3510003.3510178`. Claims: Tables 1 and 2; motivating example: Figure 1; original setup: Section 4.1.3.

[2] PERIOD authors. [Source repository and artifact instructions](https://github.com/wcventure/PERIOD). Starting commit and image digest are recorded in Section 2.1.
