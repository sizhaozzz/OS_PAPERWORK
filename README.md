# CS340 OS Project Reproduction: PERIOD (ICSE 2022)
Reproduction for paper **Controlled Concurrency Testing via Periodical Scheduling** (ICSE 2022).
Original paper: https://wcventure.github.io/pdf/ICSE2022_PERIOD.pdf
Original source repository: https://github.com/wcventure/PERIOD

## Project Overview
PERIOD is a Controlled Concurrency Testing(CCT) tool that uses **periodical scheduling** to explore thread‑interleaving space for multi‑threaded C/C++ pthread programs.
This reproduction targets three core claims from original paper:
1. **Claim‑1(RQ1 Table2)**: Parallel scheduler significantly reduces schedule search space compared with serialized scheduler, detecting more bugs especially for programs with large thread count.
2. **Claim‑2(RQ2 Table1, Figure6)**: PERIOD outperforms state‑of‑art CCT tools (IPB, IDB, PCT, Maple, Random) on bug‑finding capability over CVE‑benchmark and SCTBench.
3. **Claim‑3(RQ3 Figure7)**: PERIOD brings lower runtime overhead than IPB / IDB / PCT compared to native execution.

### Scope of Reproduction
- Workloads: CVE‑benchmark, subset of SCTBench
- Reproduce: Table1 partial results, Table2 partial results, cumulative bug‑found curve(Figure6), overhead bar chart(Figure7)
- Extension experiment: Evaluate how different period‑bound value impacts bug‑detection rate & runtime overhead.
- Not reproduced: 20 open‑source real‑world programs and 5 previously‑unknown bugs discovery experiment.

## Original Code Version
Original repository commit hash:
File `original-commit-hash.txt` stores this value.

## Environment Requirement
Paper original environment:
- Hardware: Intel Xeon Silver 4214
- OS: Ubuntu 18.04, Linux kernel with **SCHED_DEADLINE** support
- GCC‑7.5, LLVM‑10.0

Our reproduction environment:
- CPU:
- OS:
- Kernel version:
- GCC version:
- LLVM version:

## Quick Setup
> We provide `setup.sh` for dependency installation.
```bash
chmod +x setup.sh
./setup.sh
