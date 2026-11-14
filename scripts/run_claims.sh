#!/usr/bin/env bash
set -Eeuo pipefail

CLAIM="all"
REPS=3
RUNS_LIMIT=10000
C1_DEPTH=5
C2_DEPTH=3
CASE_TIMEOUT=1800

while [[ $# -gt 0 ]]; do
    case "$1" in
        --claim) CLAIM="$2"; shift 2 ;;
        --reps) REPS="$2"; shift 2 ;;
        --runs) RUNS_LIMIT="$2"; shift 2 ;;
        --timeout) CASE_TIMEOUT="$2"; shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--claim all|c1|c2] [--reps 3] [--runs 10000] [--timeout 1800]" >&2
            exit 1
            ;;
    esac
done

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR="${ROOT_DIR:-/workdir/PERIOD}"
export PATH="$ROOT_DIR/clang+llvm/bin:$ROOT_DIR/tool/SVF/Release-build/bin:$PATH"
export LD_LIBRARY_PATH="$ROOT_DIR/clang+llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

expected_commit=b6f72a7b06d01ffa7114b640312873ec2578a5ea
test "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$expected_commit"

run_id="experiments-${CLAIM}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
report="$repo/results/$run_id"
work="$(mktemp -d /workdir/period-experiments.XXXXXX)"
mkdir -p "$report"

exec > >(tee "$report/experiments.log") 2>&1
printf 'RUN_ID=%s\nWORK=%s\nCLAIM=%s\nREPS=%s\nRUNS_LIMIT=%s\n' \
    "$run_id" "$work" "$CLAIM" "$REPS" "$RUNS_LIMIT"

{
    date -u --iso-8601=seconds
    uname -a
    cat /etc/os-release
    git -C "$ROOT_DIR" rev-parse HEAD
    git -C "$ROOT_DIR" status --short
    clang --version
    gcc --version
    python3 --version
    python3 -c 'import numpy, sysv_ipc; print("numpy", numpy.__version__); print("sysv_ipc", sysv_ipc.__version__)'
    lscpu
    free -b
} > "$report/environment.log"

python3 - <<'PY'
import ctypes, os, platform
if platform.machine() != "x86_64":
    raise RuntimeError("The sched_setattr probe requires Linux x86_64")
class SchedAttr(ctypes.Structure):
    _fields_ = [
        ("size", ctypes.c_uint32), ("policy", ctypes.c_uint32),
        ("flags", ctypes.c_uint64), ("nice", ctypes.c_int32),
        ("priority", ctypes.c_uint32), ("runtime", ctypes.c_uint64),
        ("deadline", ctypes.c_uint64), ("period", ctypes.c_uint64),
    ]
attr = SchedAttr(ctypes.sizeof(SchedAttr), 6, 0, 0, 0, 1000000, 10000000, 10000000)
libc = ctypes.CDLL(None, use_errno=True)
if libc.syscall(314, 0, ctypes.byref(attr), 0) != 0:
    err = ctypes.get_errno()
    raise OSError(err, os.strerror(err))
print("PASS: SCHED_DEADLINE")
PY

# Build a Serial (SBPSched) runner from the working run_PDS.py so uint16_t shared-memory layout matches DBDSFunction.o
python3 - <<PY
from pathlib import Path
src = Path("$ROOT_DIR/tool/DBDS/run_PDS.py").read_text(encoding="utf-8")
src = "import sys\nsys.path.insert(0, '$ROOT_DIR/tool/DBDS')\nfrom sbp_sched import SBPSched\n" + src
replacements = [
    (
        "kpMaxNumArray_after_DryRun = copy.deepcopy(kpMaxNumArray)\nperiod_limit = bugDepth + 1",
        "kpMaxNumArray_after_DryRun = copy.deepcopy(kpMaxNumArray)\nperiod_limit = bugDepth + N - 1",
    ),
    ("for iterPeriod in range(2, period_limit+1):", "for iterPeriod in range(N_after_DryRun, period_limit+1):"),
    ("if VarModeFlag == 0 or iterPeriod == 2:", "if VarModeFlag == 0 or (iterPeriod - N_after_DryRun + 1 < 2):"),
    ("if (iterPeriod == 2):", "if (iterPeriod - N_after_DryRun + 1 < 2):"),
    ("if DBDS_stage == 1 and iterPeriod-1 >= 4 and full_deep_run == 0:", "if DBDS_stage == 1 and iterPeriod - N_after_DryRun + 1 >= 4 and full_deep_run == 0:"),
    ("SBPMESched(tempL[2], tmpMList, iterPeriod, prefix, fix_prefix=True)", "SBPSched(tempL[2], tmpMList, iterPeriod, prefix)"),
]
for old, new in replacements:
    assert old in src, "Missing expected snippet: " + old
    src = src.replace(old, new)
assert "SBPMESched" in src
src = src.replace("SBPMESched", "SBPSched")
Path("$work/run_OldPDS_patched.py").write_text(src, encoding="utf-8")
print("Built Serial SBPSched runner from run_PDS.py")
PY

build_upstream_dir() {
    local src_dir="$1"
    local dst_dir="$2"
    local build_log="$3"

    (
        set -x
        cd "$src_dir"
        if [[ -f ./cleanDIR.sh ]]; then
            bash ./cleanDIR.sh || true
        fi
        if [[ -f ./build.sh ]]; then
            bash ./build.sh
        else
            echo "ERROR: build.sh not found in $src_dir" >&2
            exit 1
        fi
    ) > "$build_log" 2>&1

    rm -rf "$dst_dir"
    mkdir -p "$(dirname "$dst_dir")"
    cp -a "$src_dir" "$dst_dir"

    (
        cd "$src_dir"
        if [[ -f ./cleanDIR.sh ]]; then
            bash ./cleanDIR.sh || true
        fi
    ) >/dev/null 2>&1
}

find_binary() {
    local dir="$1"
    local hint="$2"
    if [[ -x "$dir/$hint" && ! -d "$dir/$hint" ]]; then
        echo "$hint"
        return 0
    fi
    local stripped="${hint#CVE-}"
    if [[ -x "$dir/$stripped" && ! -d "$dir/$stripped" ]]; then
        echo "$stripped"
        return 0
    fi
    local candidate
    candidate=$(find "$dir" -maxdepth 1 -type f -executable \
        ! -name '*.sh' ! -name '*.py' ! -name '*.bc' ! -name '*.o' ! -name '*.so' \
        -printf '%f\n' | head -n 1 || true)
    if [[ -n "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi
    return 1
}

run_invocation() {
    local work_dir="$1"
    local runner_script="$2"
    local depth="$3"
    local binary="$4"
    local log_file="$5"

    (
        cd "$work_dir"
        rm -rf out_*
        set +e
        timeout --kill-after=10 "$CASE_TIMEOUT" \
            python3 -u "$runner_script" -y -d "$depth" --runs="$RUNS_LIMIT" "./$binary"
        rc=$?
        set -e
        printf '\nEXIT_CODE=%d\n' "$rc"
    ) > "$log_file" 2>&1
}

if [[ "$CLAIM" == "all" || "$CLAIM" == "c1" ]]; then
    CVE_LIST=(
        CVE-2009-3547
        CVE-2011-2183
        CVE-2013-1792
        CVE-2015-7550
        CVE-2016-1972
        CVE-2016-1973
        CVE-2016-7911
        CVE-2016-9806
        CVE-2017-6346
        CVE-2017-15265
    )

    mkdir -p "$report/c1"
    for cve in "${CVE_LIST[@]}"; do
        src="$ROOT_DIR/evaluation/ConVul-CVE-Benchmarks/$cve"
        bld="$work/c1/$cve/build"
        echo "=== [C1] Building $cve ==="
        if ! build_upstream_dir "$src" "$bld" "$report/c1/${cve}-build.log"; then
            echo "WARN: Build failed for $cve (see $report/c1/${cve}-build.log)"
            continue
        fi
        bin_name="$(find_binary "$bld" "$cve" || true)"
        if [[ -z "$bin_name" ]]; then
            echo "WARN: No executable found for $cve in $bld"
            continue
        fi
        echo "Built $cve -> binary=$bin_name"

        for rep in $(seq 1 "$REPS"); do
            rep_dir="$work/c1/$cve/rep${rep}"
            cp -a "$bld" "$rep_dir"
            echo "--- [C1] Running $cve (PERIOD, d=$C1_DEPTH, rep=$rep/$REPS) ---"
            run_invocation "$rep_dir" "$ROOT_DIR/tool/DBDS/run_PDS.py" "$C1_DEPTH" "$bin_name" \
                "$report/c1/${cve}-PERIOD-rep${rep}.log"
        done
    done
fi

if [[ "$CLAIM" == "all" || "$CLAIM" == "c2" ]]; then
    REORDER_LIST=(
        reorder_3
        reorder_4
        reorder_5
        reorder_10
    )

    mkdir -p "$report/c2"
    for prog in "${REORDER_LIST[@]}"; do
        src="$ROOT_DIR/evaluation/CS/$prog"
        bld="$work/c2/$prog/build"
        echo "=== [C2] Building $prog ==="
        if ! build_upstream_dir "$src" "$bld" "$report/c2/${prog}-build.log"; then
            echo "WARN: Build failed for $prog (see $report/c2/${prog}-build.log)"
            continue
        fi
        bin_name="$(find_binary "$bld" "$prog" || true)"
        if [[ -z "$bin_name" ]]; then
            echo "WARN: No executable found for $prog in $bld"
            continue
        fi
        echo "Built $prog -> binary=$bin_name"

        for sched in PERIOD Serial; do
            if [[ "$sched" == "PERIOD" ]]; then
                runner="$ROOT_DIR/tool/DBDS/run_PDS.py"
            else
                runner="$work/run_OldPDS_patched.py"
            fi

            for rep in $(seq 1 "$REPS"); do
                rep_dir="$work/c2/$prog/${sched}-rep${rep}"
                cp -a "$bld" "$rep_dir"
                echo "--- [C2] Running $prog ($sched, d=$C2_DEPTH, rep=$rep/$REPS) ---"
                run_invocation "$rep_dir" "$runner" "$C2_DEPTH" "$bin_name" \
                    "$report/c2/${prog}-${sched}-rep${rep}.log"
            done
        done
    done
fi

python3 "$repo/scripts/summarize_claims.py" "$report" "$work" "$RUNS_LIMIT"
git -C "$ROOT_DIR" status --short > "$report/upstream-status-after.txt"
echo "EXPERIMENTS_DONE=$report"

python3 "$repo/scripts/summarize_claims.py" "$report" "$work" "$RUNS_LIMIT"
git -C "$ROOT_DIR" status --short > "$report/upstream-status-after.txt"
echo "EXPERIMENTS_DONE=$report"
