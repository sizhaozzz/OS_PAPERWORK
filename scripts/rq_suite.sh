#!/usr/bin/env bash
# In-container experiments for the four research questions:
#   RQ1: Parallel scheduler (PDS) vs Serial (SS) -- covered by C2, not re-run here.
#   RQ2: PERIOD bug-finding on more SCTBench workloads (vs paper's SOTA numbers).
#   RQ3: Hyperparameter sensitivity -- grid of bug depth d x period bound.
#   RQ4: Runtime overhead of the Linux SCHED_DEADLINE scheduling mechanism.
# Mirrors the proven build/run pattern from run_claims.sh / extension.sh.
set -Eeuo pipefail

SUITE="all"          # all | rq2 | rq3 | rq4
REPS=1
RUNS_LIMIT=5000
CASE_TIMEOUT=240
PROGRAMS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite) SUITE="$2"; shift 2 ;;
        --reps) REPS="$2"; shift 2 ;;
        --runs) RUNS_LIMIT="$2"; shift 2 ;;
        --timeout) CASE_TIMEOUT="$2"; shift 2 ;;
        --programs) PROGRAMS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR="${ROOT_DIR:-/workdir/PERIOD}"
export PATH="$ROOT_DIR/clang+llvm/bin:$ROOT_DIR/tool/SVF/Release-build/bin:$PATH"
export LD_LIBRARY_PATH="$ROOT_DIR/clang+llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

expected_commit=b6f72a7b06d01ffa7114b640312873ec2578a5ea
test "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$expected_commit"

run_id="rq-${SUITE}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
report="$repo/results/$run_id"
work="$(mktemp -d /workdir/period-rq.XXXXXX)"
mkdir -p "$report/rq2" "$report/rq3" "$report/rq4"
exec > >(tee "$report/rq.log") 2>&1
printf 'RUN_ID=%s\nSUITE=%s\nREPS=%s\nRUNS_LIMIT=%s\nCASE_TIMEOUT=%s\nWORK=%s\n' \
    "$run_id" "$SUITE" "$REPS" "$RUNS_LIMIT" "$CASE_TIMEOUT" "$work"

{
    date -u --iso-8601=seconds
    uname -a
    cat /etc/os-release
    git -C "$ROOT_DIR" rev-parse HEAD
    nproc
    lscpu | grep -E 'CPU\(s\)|Model name' || true
    clang --version | head -1
    gcc --version | head -1
    python3 --version
    python3 -c 'import numpy, sysv_ipc; print("numpy", numpy.__version__)'
} > "$report/environment.log"

python3 - <<'PY'
import ctypes, os, platform
if platform.machine() != "x86_64":
    raise RuntimeError("sched_setattr probe needs Linux x86_64")
class SchedAttr(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32), ("policy", ctypes.c_uint32),
        ("flags", ctypes.c_uint64), ("nice", ctypes.c_int32),
        ("priority", ctypes.c_uint32), ("runtime", ctypes.c_uint64),
        ("deadline", ctypes.c_uint64), ("period", ctypes.c_uint64),
    ]
a = SchedAttr(ctypes.sizeof(SchedAttr), 6, 0, 0, 0, 1000000, 10000000, 10000000)
libc = ctypes.CDLL(None, use_errno=True)
if libc.syscall(314, 0, ctypes.byref(a), 0) != 0:
    e = ctypes.get_errno()
    raise OSError(e, os.strerror(e))
print("PASS: SCHED_DEADLINE")
PY

build_upstream_dir() {
    local src_dir="$1" dst_dir="$2" build_log="$3"
    (
        set -x
        cd "$src_dir"
        if [[ -f ./cleanDIR.sh ]]; then bash ./cleanDIR.sh || true; fi
        bash ./build.sh
    ) > "$build_log" 2>&1
    rm -rf "$dst_dir"
    mkdir -p "$(dirname "$dst_dir")"
    cp -a "$src_dir" "$dst_dir"
    (
        cd "$src_dir"
        if [[ -f ./cleanDIR.sh ]]; then bash ./cleanDIR.sh || true; fi
    ) >/dev/null 2>&1
}

find_binary() {
    local dir="$1" hint="$2"
    if [[ -x "$dir/$hint" && ! -d "$dir/$hint" ]]; then echo "$hint"; return 0; fi
    local stripped="${hint#CVE-}"
    if [[ -x "$dir/$stripped" && ! -d "$dir/$stripped" ]]; then echo "$stripped"; return 0; fi
    local candidate
    candidate=$(find "$dir" -maxdepth 1 -type f -executable \
        ! -name '*.sh' ! -name '*.py' ! -name '*.bc' ! -name '*.o' ! -name '*.so' \
        -printf '%f\n' | head -n 1 || true)
    [[ -n "$candidate" ]] && { echo "$candidate"; return 0; }
    return 1
}

discover_programs() {
    find "$ROOT_DIR/evaluation/CS" -mindepth 2 -maxdepth 2 -name build.sh -printf '%h\n' \
        | xargs -n1 basename | grep -v '^reorder_' | sort
}

run_invocation() {
    local work_dir="$1" runner="$2" depth="$3" binary="$4" log_file="$5"
    local timeout_s="$6" runs="$7"
    local extra_env="${8:-}"
    (
        cd "$work_dir"
        rm -rf out_*
        set +e
        # The patched RQ3 runner lives outside tool/DBDS, so make its sibling
        # modules (interleaving, sched, ipc, ...) importable.
        env PYTHONPATH="$ROOT_DIR/tool/DBDS${PYTHONPATH:+:$PYTHONPATH}" \
            $extra_env timeout --kill-after=10 "$timeout_s" \
            python3 -u "$runner" -y -d "$depth" --runs="$runs" "./$binary"
        rc=$?
        set -e
        printf '\nEXIT_CODE=%d\n' "$rc"
    ) > "$log_file" 2>&1
}

# ---------------------------------------------------------------- RQ2
if [[ "$SUITE" == "all" || "$SUITE" == "rq2" ]]; then
    echo "=== RQ2: PERIOD bug-finding on additional workloads ==="
    progs="${PROGRAMS:-$(discover_programs | head -n 8 | tr '\n' ' ')}"
    for prog in $progs; do
        src="$ROOT_DIR/evaluation/CS/$prog"
        bld="$work/rq2/$prog/build"
        echo "--- [RQ2] Building $prog ---"
        build_upstream_dir "$src" "$bld" "$report/rq2/${prog}-build.log" || { echo "WARN build $prog"; continue; }
        bin_name="$(find_binary "$bld" "$prog" || true)"
        [[ -n "$bin_name" ]] || { echo "WARN bin $prog"; continue; }
        for rep in $(seq 1 "$REPS"); do
            rep_dir="$work/rq2/$prog/rep${rep}"
            cp -a "$bld" "$rep_dir"
            echo "--- [RQ2] $prog rep=$rep/$REPS ---"
            run_invocation "$rep_dir" "$ROOT_DIR/tool/DBDS/run_PDS.py" 3 "$bin_name" \
                "$report/rq2/${prog}-rep${rep}.log" "$CASE_TIMEOUT" "$RUNS_LIMIT"
        done
    done
fi

# ---------------------------------------------------------------- RQ3
if [[ "$SUITE" == "all" || "$SUITE" == "rq3" ]]; then
    echo "=== RQ3: hyperparameter sensitivity (bug depth d x period bound) ==="
    # Patch a runner variant that decouples period_limit from bugDepth via env.
    patched="$work/run_PDS_period.py"
    python3 - <<PY
from pathlib import Path
src = Path("$ROOT_DIR/tool/DBDS/run_PDS.py").read_text(encoding="utf-8")
old = "period_limit = bugDepth + 1\n\nfor iterPeriod in range(2, period_limit+1):"
new = ("period_limit = bugDepth + 1\n"
       "import os as _os\n"
       "_ov = _os.environ.get('PERIOD_OVERRIDE')\n"
       "if _ov:\n"
       "    period_limit = int(_ov)\n"
       "    print('PERIOD_OVERRIDE:', period_limit)\n"
       "\nfor iterPeriod in range(2, period_limit+1):")
assert old in src, "period patch anchor missing"
src = src.replace(old, new, 1)
Path("$patched").write_text(src, encoding="utf-8")
print("Patched runner written to $patched")
PY
    prog="reorder_5"
    src="$ROOT_DIR/evaluation/CS/$prog"
    bld="$work/rq3/$prog/build"
    build_upstream_dir "$src" "$bld" "$report/rq3/${prog}-build.log" || echo "WARN build $prog"
    bin_name="$(find_binary "$bld" "$prog" || true)"
    if [[ -n "$bin_name" ]]; then
        for d in 2 3; do
            for p in 2 3 4 5; do
                for rep in $(seq 1 "$REPS"); do
                    tag="d${d}-p${p}-rep${rep}"
                    rep_dir="$work/rq3/${prog}/${tag}"
                    cp -a "$bld" "$rep_dir"
                    echo "--- [RQ3] $prog d=$d period=$p rep=$rep ---"
                    run_invocation "$rep_dir" "$patched" "$d" "$bin_name" \
                        "$report/rq3/${prog}-${tag}.log" "$CASE_TIMEOUT" "$RUNS_LIMIT" \
                        "PERIOD_OVERRIDE=$p"
                done
            done
        done
    fi
fi

# ---------------------------------------------------------------- RQ4
if [[ "$SUITE" == "all" || "$SUITE" == "rq4" ]]; then
    echo "=== RQ4: SCHED_DEADLINE kernel scheduling overhead ==="
    # Micro-benchmark: N threads each perform Y yield() calls. Compare wall-clock
    # with plain CFS scheduling vs all threads pinned to SCHED_DEADLINE.
    cat > "$report/rq4/deadline_overhead.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <time.h>
#include <errno.h>
#include <string.h>
#include <sys/syscall.h>

static int NTHREADS = 1;
static int NYIELDS = 50;
static int USE_DEADLINE = 0;

static void set_deadline(void) {
    struct sched_attr {
        uint32_t size; uint32_t policy; uint64_t flags;
        int32_t nice; uint32_t priority;
        uint64_t runtime, deadline, period;
    } attr;
    memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.policy = 6;                /* SCHED_DEADLINE */
    attr.runtime = 20000000;        /* 20 ms */
    attr.deadline = 20000000;       /* 20 ms */
    attr.period = 20000000;         /* 20 ms (no throttling, one yield = one period) */
    if (syscall(314, 0, &attr, 0) != 0) {
        fprintf(stderr, "sched_setattr failed: %s\n", strerror(errno));
        pthread_exit(NULL);
    }
}

static void *worker(void *arg) {
    if (USE_DEADLINE) set_deadline();
    for (int i = 0; i < NYIELDS; i++) sched_yield();
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1) NTHREADS = atoi(argv[1]);
    if (argc > 2) NYIELDS = atoi(argv[2]);
    if (argc > 3) USE_DEADLINE = atoi(argv[3]);
    pthread_t th[256];
    if (NTHREADS > 256) return 2;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < NTHREADS; i++) pthread_create(&th[i], NULL, worker, NULL);
    for (int i = 0; i < NTHREADS; i++) pthread_join(th[i], NULL);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double sec = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("threads=%d yields=%d deadline=%d wall_sec=%.6f\n",
           NTHREADS, NYIELDS, USE_DEADLINE, sec);
    return 0;
}
C
    gcc -O2 -pthread -o "$report/rq4/deadline_overhead" "$report/rq4/deadline_overhead.c"
    # Each sched_yield under SCHED_DEADLINE costs about one 20 ms period, so
    # keep the yield count small enough to finish while still showing the
    # per-yield scheduling cost clearly.
    for nt in 1 4; do
        for mode in 0 1; do
            for rep in 1 2 3; do
                echo "--- [RQ4] threads=$nt deadline=$mode rep=$rep ---"
                "$report/rq4/deadline_overhead" "$nt" 50 "$mode" \
                    >> "$report/rq4/overhead.log" 2>&1 || \
                    echo "threads=$nt deadline=$mode rep=$rep FAILED" >> "$report/rq4/overhead.log"
            done
        done
    done
    cat "$report/rq4/overhead.log"
fi

python3 "$repo/scripts/summarize_rq.py" "$report"
git -C "$ROOT_DIR" status --short > "$report/upstream-status-after.txt"
echo "RQ_SUITE_DONE=$report"
