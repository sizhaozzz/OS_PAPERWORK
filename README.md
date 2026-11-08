# PERIOD Paper Replication

This repository contains the Introduction and Claims and Reproduction Setup for an initial replication of *Controlled Concurrency Testing via Periodical Scheduling*, together with two environment-validation programs, their output and test results. The supplied [Word document](docs/PERIOD_Introduction_and_Setup.docx) is retained as provided.

## 1 Introduction and Claims

### 1.1 Paper and problem

Wen et al.'s ICSE 2022 paper addresses concurrency bugs that occur only under particular thread interleavings. Repeated execution under the native scheduler may miss those interleavings, while exhaustive exploration becomes expensive as the number of threads and scheduling points increases [1, Sections 1 and 2].

PERIOD models execution as a sequence of periods and uses Linux deadline scheduling to control the order of instrumented key points. It explores schedules with increasing period bounds and uses feedback from observed execution paths to guide further exploration. Allowing threads to execute in parallel in the last period reduces the schedule space compared with fully serialized execution [1, Sections 3.2-3.4].

### 1.2 Claims selected for testing

These are the two claims selected for the planned reproduction. The current environment tests do not establish either claim across its planned workload set.

| Claim | Paper evidence | Planned measurements |
| --- | --- | --- |
| C1: PERIOD detects the 15 reported concurrency bugs across the 10 CVE programs, including null-pointer dereference, use-after-free and double-free. | Table 1 | Detected error types, schedules to the first error, total schedules and buggy schedules for each CVE program. |
| C2: PERIOD's parallel scheduler explores fewer schedules than Serial on selected reorder programs. | Table 2; Section 4.2 | Total schedules, schedules to the first assertion failure and whether a bug is found, for both schedulers with 3, 4, 5 and 10 subthreads. |

For C2, Table 2 reports PERIOD schedule counts of 27, 100, 225 and 2,350 for those four thread counts. The corresponding Serial results are 30, 384, 5,040 and the 10,000-schedule limit. The targets follow Table 2; a sentence in Section 4.2 gives a different value for the four-thread Serial case.

### 1.3 Scope and current stage

The planned scope is all 10 CVE programs and four SCTBench reorder programs, compared with the paper's 10 CVE and 36 SCTBench programs. C1 will use PERIOD; C2 will compare PERIOD with Serial. Other competing tools, Figure 7 runtime-overhead experiments and discovery of new bugs are outside this scope.

The completed work is environment validation using the author's doubleFree example and CVE-2016-1972 user-space model. The remaining CVEs, reorder workloads and Serial comparisons have not been run for this package. No full claim verdict or paper-level performance result is asserted.

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

No tracked upstream source files were modified. The following two source files are copied unchanged from that artifact:

| Repository file | Original path |
| --- | --- |
| `benchmarks/doubleFree/df.c` | `test/doubleFree/df.c` |
| `benchmarks/CVE-2016-1972/2016-1972.c` | `evaluation/ConVul-CVE-Benchmarks/CVE-2016-1972/2016-1972.c` |

Local additions are this README, `.gitignore`, `.gitattributes`, four scripts under `scripts/`, the supplied document under `docs/`, and the test records under `results/`. `run-tests.sh` starts the pinned container; `validate.sh` builds and tests the programs; `summarize.py` saves error schedules, verifies representative replays and summarizes output; `verify-results.py` checks existing logs and regenerates the CSV index. The original MIT license is retained in [third_party/PERIOD-LICENSE](third_party/PERIOD-LICENSE).

The original installation used separate local WSL setup and startup scripts, as described in the Word document. Its Windows mirrored-networking and proxy configuration supported image installation. The runner included here requires a working Docker installation and does not change those host settings or PERIOD's scheduling algorithm.

### 2.2 Environment

The following settings describe the validation environment recorded on 6 November 2026. Compiler and kernel versions, CPU details and container-visible memory are recorded in [environment.log](results/validation-20261106T123317Z-1/environment.log). Host OS, physical hardware and Docker/WSL versions are also documented in the supplied Word file.

| Component | Setting used |
| --- | --- |
| Host hardware | Intel Core i7-14650HX; 16 physical cores and 24 logical processors; approximately 16 GiB host RAM |
| Host OS | Windows 11 Pro, build 22631.3880 |
| Virtualization | WSL 3.0.3.0; outer Ubuntu 22.04 distribution |
| Linux kernel | `6.18.54.1-microsoft-standard-WSL2`, x86_64 |
| Container-visible resources | 24 logical CPUs; approximately 7.6 GiB RAM and 2 GiB swap |
| Container userspace | Ubuntu 18.04.5 LTS |
| Compiler and analysis tools | GCC 7.5.0; Clang/LLVM 10.0.0; bundled SVF and PERIOD instrumentation |
| Python dependencies | Python 3.6.9; NumPy 1.19.5; sysv_ipc 1.1.0 |
| Container runtime | Docker Engine 29.1.3; privileged execution; container networking disabled |
| Scheduling settings | SCHED_DEADLINE probe passed; no added CPU affinity or container CPU/memory cap |

The container shares the WSL2 kernel. It does not supply a separate Ubuntu 18.04 kernel. `ROOT_DIR`, `PATH` and `LD_LIBRARY_PATH` are set by the test script.

### 2.3 Workloads and inputs

| Workload | Source and inputs | Status |
| --- | --- | --- |
| doubleFree | Author's `test/doubleFree/df.c`; two pthreads operate on shared allocated memory initialized in `main`. | Included and tested as an environment smoke test. |
| CVE-2016-1972 | Author's `evaluation/ConVul-CVE-Benchmarks/CVE-2016-1972/2016-1972.c`; user-space pthread model corresponding to the motivating example in Figure 1. | Included and tested for environment validation. |
| Remaining CVE programs | Author image's `evaluation/ConVul-CVE-Benchmarks/`. | Planned for C1; not included as completed experiments. |
| Four reorder programs | Author image's `evaluation/CS/reorder_3`, `reorder_4`, `reorder_5` and `reorder_10`. | Planned for C2; not included as completed experiments. |

The included C sources were exported from the pinned image. They initialize their own state and do not require an external dataset. PERIOD generates the thread schedules used as test inputs. These workloads are small benchmark models rather than complete historical Firefox or Linux installations.

The actual validation commands use bug-depth bound 3 for doubleFree and bound 5 with a 10,000-schedule budget for the CVE model. The wrapper imposes overall exploration limits of 120 and 600 seconds respectively; the tool's per-execution timeout is left at its default. Representative failing schedules are saved and replayed.

The planned main experiments use bug-depth bound 5 for C1 and 3 for C2, a 10,000-schedule budget and three repetitions per program/scheduler configuration. These planned repetitions are separate from the three environment-validation executions below.

### 2.4 Deviations from the paper

| Item | Paper setting | Used or planned setting | Reason and implication |
| --- | --- | --- | --- |
| CPU | Intel Xeon Silver 4214 workstation | Intel Core i7-14650HX laptop | Available hardware; timing and scheduling behavior may differ. |
| OS and kernel | Ubuntu 18.04; exact kernel unspecified | Ubuntu 18.04.5 container on Ubuntu 22.04/WSL2 kernel `6.18.54.1` | Enables Windows-hosted testing; kernel behavior is not identical to the original native setup. |
| Main workload coverage | 10 CVE and 36 SCTBench programs | Planned: 10 CVEs and four reorder programs. Completed: two environment-test programs only. | Reduced project scope and current setup stage. |
| Compared techniques | Serial, other CCT techniques and additional detectors | Planned: PERIOD for C1; PERIOD versus Serial for C2. Validation currently uses PERIOD only. | Focuses on the two selected claims. |
| Main experiment repetitions | 10 per program and technique | Three per configuration planned | Lower experiment cost; less statistical precision. |
| Execution settings | Exact CPU affinity and per-execution timeout not specified | No added affinity; tool default timeout retained; overall wrapper limits of 120/600 seconds for validation | Records local settings and prevents unbounded validation runs. |
| Build procedure | Author artifact and toolchain | Same artifact/compiler versions; isolated source copies built by local wrapper scripts | Preserves upstream files and existing results. |
| Test containers | Paper's container lifecycle not specified | First two validations in the installed container; third in a fresh disposable container | The third run checks the packaged runner; these are not a controlled three-run main experiment. |

The reported Ubuntu userspace, GCC and LLVM versions align with the paper. Passing the scheduling probe verifies availability of the required interface; it does not establish equivalent performance.

### 2.5 Environment test programs, output and results

Use an x86_64 Linux or WSL2 host with at least two logical CPUs and a working Docker installation that permits privileged containers. From this repository's root:

```bash
bash scripts/run-tests.sh
```

The script downloads the pinned image only if absent, builds fresh instrumented programs in a temporary container, and writes a new run directory under `results/`. Container networking is disabled during testing. Existing results are preserved; compiled products are discarded when the container exits. The observed initial exploration phases took approximately 4 seconds for doubleFree and 26-42 seconds for the CVE model, excluding image download, compilation and replay.

The underlying commands after compilation are:

```bash
python3 -u "$ROOT_DIR/tool/DBDS/run_PDS.py" -y -d 3 ./df
python3 -u "$ROOT_DIR/tool/DBDS/run_PDS.py" -y -d 5 --runs=10000 ./2016-1972
```

All recorded validations were executed on 6 November 2026. The initial directory timestamps use UTC, and the final identifier explicitly includes `Z`. Full records are indexed in [results/summary.csv](results/summary.csv).

| Run | Program | Schedules | Error interleavings | SEGV | Use-after-free | Double-free | Timeouts |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `initial-validation-20261106-122033` | doubleFree | 6 | 4 | 0 | 0 | 4 | 0 |
| `initial-validation-20261106-122033` | CVE-2016-1972 | 346 | 25 | 15 | 9 | 1 | 0 |
| `initial-validation-20261106-122202` | doubleFree | 6 | 4 | 0 | 0 | 4 | 0 |
| `initial-validation-20261106-122202` | CVE-2016-1972 | 346 | 28 | 16 | 11 | 1 | 0 |
| `validation-20261106T123317Z-1` | doubleFree | 6 | 4 | 0 | 0 | 4 | 0 |
| `validation-20261106T123317Z-1` | CVE-2016-1972 | 354 | 28 | 16 | 11 | 1 | 0 |

Each run directory contains `environment.log`, `*-build.log`, `*-test.log`, `*-replay-*.log`, `summary.json`, `validation.log`, `upstream-status-after.txt` and `schedules/`. These retain the environment, compiler output, full test output, ASan replay output and every saved error interleaving. Empty upstream-status files record no tracked upstream changes.

The scheduling probe, dependency imports, compilation, static analysis, instrumentation and representative error replays passed. Error interleavings count failing schedules, not distinct vulnerabilities. SEGV is retained as the tool's output label; the representative replay shows a write near address zero. These expected errors indicate detection of intentionally buggy programs.

The varying CVE counts and the difference from Table 1's 573 schedules remain unexplained. These checks establish a working validation pipeline, not numerical reproduction of the paper. In the first run, the console summary originally reported 10 CVE schedules because its parser omitted records containing `for prefix`; its JSON summary was corrected to 346 against the complete test log. The original `validation.log` retains that historical console output.

Check all preserved test records without Docker:

```powershell
python -B scripts/verify-results.py
```

On Linux use `python3 -B` instead of `python -B`. Adding `--write-index` regenerates `results/summary.csv`. This check compares source hashes with build logs, schedule counters, saved error files and replay records.

The supplied Word document retains your saved content and describes the earlier setup stage. The table above records the later CVE environment checks. Its broader reproduction plan remains planned work.

### 2.6 References

[1] C. Wen, M. He, B. Wu, Z. Xu and S. Qin. *Controlled Concurrency Testing via Periodical Scheduling*. ICSE 2022. DOI: `10.1145/3510003.3510178`. Claims: Tables 1 and 2; motivating example: Figure 1; original setup: Section 4.1.3.

[2] PERIOD authors. [Source repository and artifact instructions](https://github.com/wcventure/PERIOD). Starting commit and image digest are recorded in Section 2.1.
