#!/usr/bin/env bash
# In-container extension experiment: vary the bug-depth bound d on a fixed
# workload (reorder_5) and scheduler (PERIOD). One factor changes at a time.
set -Eeuo pipefail

REPS=3
RUNS_LIMIT=10000
CASE_TIMEOUT=1800
DEPTHS="2 3 4 5"
PROGRAM=reorder_5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reps) REPS="$2"; shift 2 ;;
        --runs) RUNS_LIMIT="$2"; shift 2 ;;
        --timeout) CASE_TIMEOUT="$2"; shift 2 ;;
        --depths) DEPTHS="$2"; shift 2 ;;
        --program) PROGRAM="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR="${ROOT_DIR:-/workdir/PERIOD}"
export PATH="$ROOT_DIR/clang+llvm/bin:$ROOT_DIR/tool/SVF/Release-build/bin:$PATH"
export LD_LIBRARY_PATH="$ROOT_DIR/clang+llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

expected_commit=b6f72a7b06d01ffa7114b640312873ec2578a5ea
test "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$expected_commit"

run_id="extension-${PROGRAM}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
report="$repo/results/$run_id"
work="$(mktemp -d /workdir/period-extension.XXXXXX)"
mkdir -p "$report/extension"
exec > >(tee "$report/extension.log") 2>&1
printf 'RUN_ID=%s\nPROGRAM=%s\nDEPTHS=%s\nREPS=%s\nRUNS_LIMIT=%s\n' \
    "$run_id" "$PROGRAM" "$DEPTHS" "$REPS" "$RUNS_LIMIT"

{
    date -u --iso-8601=seconds
    uname -a
    cat /etc/os-release
    git -C "$ROOT_DIR" rev-parse HEAD
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
    raise RuntimeError("sched_setattr probe requires Linux x86_64")
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

src="$ROOT_DIR/evaluation/CS/$PROGRAM"
bld="$work/$PROGRAM/build"
# build.sh compiles inside the source directory (product lands in "$src");
# mirror the proven build_upstream_dir() flow from run_claims.sh: build first,
# then copy the whole source tree into "$bld", then locate the binary there.
(
    set -x
    cd "$src"
    if [[ -f ./cleanDIR.sh ]]; then bash ./cleanDIR.sh || true; fi
    bash ./build.sh
) > "$report/extension/$PROGRAM-build.log" 2>&1

rm -rf "$bld"
mkdir -p "$(dirname "$bld")"
cp -a "$src" "$bld"

bin_name=""
for candidate in "${PROGRAM}_bad" "$PROGRAM"; do
    if [[ -x "$bld/$candidate" && ! -d "$bld/$candidate" ]]; then
        bin_name="$candidate"; break
    fi
done
if [[ -z "$bin_name" ]]; then
    bin_name="$(find "$bld" -maxdepth 1 -type f -executable \
        ! -name '*.sh' ! -name '*.py' ! -name '*.bc' ! -name '*.o' ! -name '*.so' \
        -printf '%f\n' | head -n 1 || true)"
fi
test -n "$bin_name" || { echo "No executable found for $PROGRAM" >&2; exit 1; }
echo "Built $PROGRAM -> binary=$bin_name"

for depth in $DEPTHS; do
    for rep in $(seq 1 "$REPS"); do
        rep_dir="$work/${PROGRAM}-d${depth}-rep${rep}"
        cp -a "$bld" "$rep_dir"
        echo "--- [EXT] $PROGRAM d=$depth rep=$rep/$REPS ---"
        (
            cd "$rep_dir"
            rm -rf out_*
            set +e
            timeout --kill-after=10 "$CASE_TIMEOUT" \
                python3 -u "$ROOT_DIR/tool/DBDS/run_PDS.py" -y -d "$depth" \
                --runs="$RUNS_LIMIT" "./$bin_name"
            rc=$?
            set -e
            printf '\nEXIT_CODE=%d\n' "$rc"
        ) > "$report/extension/${PROGRAM}-d${depth}-rep${rep}.log" 2>&1
    done
done

python3 "$repo/scripts/summarize_extension.py" "$report" "$RUNS_LIMIT"
git -C "$ROOT_DIR" status --short > "$report/upstream-status-after.txt"
echo "EXTENSION_DONE=$report"
