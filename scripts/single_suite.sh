#!/usr/bin/env bash
# ONE unified extension experiment.
#
# A single matrix of PERIOD runs over five fixed programs (three legacy CVEs
# from 2009/2011/2016 plus reorder_5/reorder_10). From this ONE matrix we read
# all four presentation points:
#   Scalability      - reorder_10 under 1 / 4 / 16 cores
#   Compatibility    - decade-old CVE C code builds and runs on kernel 6.18
#   Security         - CAP_SYS_NICE boundary: privileged vs unprivileged
#   Reproducibility  - pinned commit/kernel/toolchain + fresh clone + verifier
#
# There are no four separate suites; --mode only selects the privilege
# context of the SAME protocol (matrix runs vs the unprivileged capability
# probe that cannot run SCHED_DEADLINE).
set -Eeuo pipefail

MODE="matrix"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

repo="/repro"
export ROOT_DIR="${ROOT_DIR:-/workdir/PERIOD}"
export PATH="$ROOT_DIR/clang+llvm/bin:$ROOT_DIR/tool/SVF/Release-build/bin:$PATH"
export LD_LIBRARY_PATH="$ROOT_DIR/clang+llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

expected_commit=b6f72a7b06d01ffa7114b640312873ec2578a5ea
test "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$expected_commit"

report="${SINGLE_REPORT:-$repo/results/single-local}"
mkdir -p "$report/matrix" "$report/security" "$report/repro"
exec > >(tee "$report/single.log") 2>&1
printf 'REPORT=%s\nMODE=%s\n' "$report" "$MODE"

work="$(mktemp -d /workdir/period-single.XXXXXX)"

{
    date -u --iso-8601=seconds
    uname -a
    cat /etc/os-release
    echo "nproc=$(nproc)"
    echo "commit=$(git -C "$ROOT_DIR" rev-parse HEAD)"
    echo "clang=$(clang --version | head -1)"
    echo "gcc=$(gcc --version | head -1)"
    echo "python=$(python3 --version)"
} > "$report/environment.log"

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

run_one() {
    local work_dir="$1" binary="$2" log_file="$3" timeout_s="$4" runs="$5"
    local cpus="${6:-}"
    (
        cd "$work_dir"
        rm -rf out_*
        set +e
        local cmd=(timeout --kill-after=10 "$timeout_s" python3 -u "$ROOT_DIR/tool/DBDS/run_PDS.py" -y -d 3 --runs="$runs" "./$binary")
        if [[ -n "$cpus" ]]; then
            cmd=(taskset -c "$cpus" "${cmd[@]}")
        fi
        env PYTHONPATH="$ROOT_DIR/tool/DBDS${PYTHONPATH:+:$PYTHONPATH}" "${cmd[@]}"
        rc=$?
        set -e
        printf '\nEXIT_CODE=%d\n' "$rc"
    ) > "$log_file" 2>&1
}

analyze_caps() {
    python3 - <<'PY'
line = next((l for l in open("/proc/self/status") if l.startswith("CapEff:")), "")
val = int(line.split()[1], 16)
nice = bool(val & (1 << 23))
print("cap_sys_nice_bit={}".format(1 if nice else 0))
if nice:
    print("CAP_SYS_NICE=present -> SCHED_DEADLINE permitted")
else:
    print("CAP_SYS_NICE=absent -> sched_setattr would fail with EPERM (Operation not permitted)")
PY
}

write_probe_c() {
    local out="$1"
    cat > "$out" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>
struct sched_attr {
    uint32_t size; uint32_t policy; uint64_t flags;
    int32_t nice; uint32_t priority;
    uint64_t runtime, deadline, period;
};
int main(void) {
    struct sched_attr a;
    memset(&a, 0, sizeof(a));
    a.size = sizeof(a);
    a.policy = 6;
    a.runtime = 20000000;
    a.deadline = 20000000;
    a.period = 20000000;
    if (syscall(314, 0, &a, 0) == 0)
        printf("PROBE_OK: SCHED_DEADLINE sched_setattr succeeded\n");
    else
        printf("PROBE_FAIL: errno=%d (%s)\n", errno, strerror(errno));
    return 0;
}
C
}

# ------------------------------------------------------------------ matrix
if [[ "$MODE" == "matrix" ]]; then
    echo "=== ONE extension experiment: unified matrix (5 programs x core budgets) ==="
    cve_root="$(find "$ROOT_DIR/evaluation" -maxdepth 2 -type d -name 'CVE-*' -printf '%h\n' | head -1)"
    echo "CVE_ROOT=$cve_root"

    for prog in CVE-2009-3547 CVE-2011-2183 CVE-2016-1972 reorder_5 reorder_10; do
        if [[ "$prog" == CVE-* ]]; then src="$cve_root/$prog"; else src="$ROOT_DIR/evaluation/CS/$prog"; fi
        [[ -f "$src/build.sh" ]] || { echo "WARN missing $prog"; continue; }
        bld="$work/matrix/$prog/build"
        echo "--- build $prog ---"
        build_upstream_dir "$src" "$bld" "$report/matrix/${prog}-build.log" || { echo "WARN build $prog"; continue; }
        bin_name="$(find_binary "$bld" "$prog" || true)"
        [[ -n "$bin_name" ]] || { echo "WARN bin $prog"; continue; }

        # all-core configuration for every program (compatibility + baseline)
        rep="$work/matrix/$prog/all"
        cp -a "$bld" "$rep"
        echo "--- run $prog all-core (budget 3000, 180s) ---"
        run_one "$rep" "$bin_name" "$report/matrix/${prog}-all.log" 180 3000

        # core-budget axis only on the mid-size reorder program (scalability).
        # Same budget and timeout as the all-core run so the comparison is fair.
        if [[ "$prog" == "reorder_10" ]]; then
            for cpus in 0 0-3; do
                tag="${cpus//-/_}"
                rep2="$work/matrix/$prog/cpus$tag"
                cp -a "$bld" "$rep2"
                echo "--- run $prog cpus=$cpus (budget 3000, 180s) ---"
                run_one "$rep2" "$bin_name" "$report/matrix/${prog}-cpus${tag}.log" 180 3000 "$cpus"
            done
        fi
    done

    # security observation from the SAME privileged process that ran the matrix
    {
        echo "context=privileged"
        echo "caps=$(grep CapEff /proc/self/status | awk '{print $2}')"
        analyze_caps
        write_probe_c "$work/sched_probe.c"
        gcc -O2 -o "$work/sched_probe" "$work/sched_probe.c" && "$work/sched_probe"
    } > "$report/security/privileged.log" 2>&1
    cat "$report/security/privileged.log"

    # reproducibility observation from the SAME run
    {
        echo "upstream_commit=$(git -C "$ROOT_DIR" rev-parse HEAD)"
        echo "expected_commit=$expected_commit"
        echo "commit_match=$([[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$expected_commit" ]] && echo yes || echo no)"
        echo "linux_kernel=$(uname -r)"
        echo "arch=$(uname -m)"
        echo "tool_versions=$(clang --version | head -1); $(gcc --version | head -1); $(python3 --version)"
    } > "$report/repro/fingerprint.log"
    fresh="$(mktemp -d /workdir/period-single-fresh.XXXXXX)"
    if git clone -q "$ROOT_DIR" "$fresh/PERIOD" 2>"$report/repro/fresh-clone.err"; then
        echo "fresh_clone=OK commit=$(git -C "$fresh/PERIOD" rev-parse HEAD)" >> "$report/repro/fingerprint.log"
    else
        echo "fresh_clone=FAIL" >> "$report/repro/fingerprint.log"
    fi
    if python3 "$repo/scripts/verify-results.py" > "$report/repro/verify.log" 2>&1; then
        echo "offline_verify=OK" >> "$report/repro/fingerprint.log"
    else
        echo "offline_verify=FAIL" >> "$report/repro/fingerprint.log"
    fi
    cat "$report/repro/fingerprint.log"
fi

# ------------------------------------------------------- unprivileged probe
if [[ "$MODE" == "unpriv" ]]; then
    echo "=== same protocol, unprivileged context: capability boundary only ==="
    {
        echo "context=unprivileged"
        echo "caps=$(grep CapEff /proc/self/status | awk '{print $2}')"
        analyze_caps
    } > "$report/security/unprivileged.log" 2>&1
    cat "$report/security/unprivileged.log"
fi

if [[ "$MODE" == "matrix" ]]; then
    python3 "$repo/scripts/summarize_single.py" "$report"
fi
echo "SINGLE_SUITE_DONE=$report MODE=$MODE"
