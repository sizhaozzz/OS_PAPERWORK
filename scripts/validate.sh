#!/usr/bin/env bash
set -Eeuo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR="${ROOT_DIR:-/workdir/PERIOD}"
export PATH="$ROOT_DIR/clang+llvm/bin:$ROOT_DIR/tool/SVF/Release-build/bin:$PATH"
export LD_LIBRARY_PATH="$ROOT_DIR/clang+llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
expected_commit=b6f72a7b06d01ffa7114b640312873ec2578a5ea
test "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$expected_commit"

# UTC identifiers are explicit; archived initial-validation identifiers used
# container UTC too, despite requesting an unavailable Asia/Shanghai timezone.
run_id="validation-$(date -u +%Y%m%dT%H%M%SZ)-$$"
report="$repo/results/$run_id"
work="$(mktemp -d /workdir/period-validation.XXXXXX)"
mkdir -p "$report"
exec > >(tee "$report/validation.log") 2>&1
printf 'RUN_ID=%s\nWORK=%s\n' "$run_id" "$work"
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
import ctypes
import os
import platform

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
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
print("PASS: SCHED_DEADLINE")
PY

build_case() {
    local label="$1" binary="$2" upstream_file="$3"
    mkdir -p "$work/$label"
    cmp "$repo/benchmarks/$label/$binary.c" "$ROOT_DIR/$upstream_file"
    cp "$repo/benchmarks/$label/$binary.c" "$work/$label/$binary.c"
    (
        set -x
        cd "$work/$label"
        sha256sum "$binary.c"
        clang -g -emit-llvm -c "$binary.c" -o "$binary.bc"
        bash "$ROOT_DIR/tool/staticAnalysis/staticAnalysis.sh" "$binary"
        export Con_PATH="$PWD/ConConfig.$binary"
        "$ROOT_DIR/tool/staticAnalysis/DBDS-INSTRU/dbds-clang-fast" \
            -g -fsanitize=address -c "$binary.c" -o "$binary.o"
        clang++ "$binary.o" "$ROOT_DIR/tool/staticAnalysis/DBDS-INSTRU/DBDSFunction.o" \
            -g -o "$binary" -lpthread -fsanitize=address -ldl
    ) > "$report/$label-build.log" 2>&1
    echo "PASS: $label compiled, statically analyzed and instrumented"
}

build_case doubleFree df test/doubleFree/df.c
(
    cd "$work/doubleFree"
    timeout --kill-after=10 120 python3 -u "$ROOT_DIR/tool/DBDS/run_PDS.py" -y -d 3 ./df
) > "$report/doubleFree-test.log" 2>&1
echo "Finished: doubleFree schedule exploration"

build_case CVE-2016-1972 2016-1972 evaluation/ConVul-CVE-Benchmarks/CVE-2016-1972/2016-1972.c
(
    cd "$work/CVE-2016-1972"
    timeout --kill-after=10 600 python3 -u "$ROOT_DIR/tool/DBDS/run_PDS.py" \
        -y -d 5 --runs=10000 ./2016-1972
) > "$report/CVE-2016-1972-test.log" 2>&1
echo "Finished: CVE-2016-1972 schedule exploration"

python3 "$repo/scripts/summarize.py" "$report" "$work" "$ROOT_DIR"
git -C "$ROOT_DIR" status --short > "$report/upstream-status-after.txt"
echo "VALIDATION_PASSED=$report"
