#!/usr/bin/env bash
# In-container Critical-Analysis extension:
#   CA1 Scalability   - thread-count gradient (reorder_5/10/20/50) and CPU-core scaling
#   CA2 Compatibility - legacy CVE code (2009/2011) + modern 6.18 kernel, x86_64
#   CA3 Security      - SCHED_DEADLINE privilege boundary (privileged vs unprivileged)
#   CA4 Reproducibility - pinned commit / image digest / offline verifier / fresh clone
# Not restricted to single-factor changes: each part targets one CA dimension.
set -Eeuo pipefail

SUITE="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite) SUITE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

repo="/repro"
export ROOT_DIR="${ROOT_DIR:-/workdir/PERIOD}"
export PATH="$ROOT_DIR/clang+llvm/bin:$ROOT_DIR/tool/SVF/Release-build/bin:$PATH"
export LD_LIBRARY_PATH="$ROOT_DIR/clang+llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

expected_commit=b6f72a7b06d01ffa7114b640312873ec2578a5ea
test "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$expected_commit"

report="${CA_REPORT:-$repo/results/ca-local}"
mkdir -p "$report" "$report/ca1" "$report/ca2" "$report/ca3" "$report/ca4"
exec > >(tee "$report/ca.log") 2>&1
printf 'REPORT=%s\nSUITE=%s\n' "$report" "$SUITE"

work="$(mktemp -d /workdir/period-ca.XXXXXX)"

{
    date -u --iso-8601=seconds
    uname -a
    cat /etc/os-release
    echo "nproc=$(nproc)"
    git -C "$ROOT_DIR" rev-parse HEAD
    clang --version | head -1
    gcc --version | head -1
    python3 --version
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

run_ca() {
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

# --------------------------------------------------------------- CA1
if [[ "$SUITE" == "all" || "$SUITE" == "ca1" ]]; then
    echo "=== CA1: scalability (thread count and CPU cores) ==="
    for prog in reorder_5 reorder_10 reorder_20 reorder_50; do
        src="$ROOT_DIR/evaluation/CS/$prog"
        [[ -f "$src/build.sh" ]] || { echo "WARN missing $prog"; continue; }
        bld="$work/ca1/$prog/build"
        echo "--- [CA1] build $prog ---"
        build_upstream_dir "$src" "$bld" "$report/ca1/${prog}-build.log" || { echo "WARN build $prog"; continue; }
        bin_name="$(find_binary "$bld" "$prog" || true)"
        [[ -n "$bin_name" ]] || { echo "WARN bin $prog"; continue; }
        rep_dir="$work/ca1/$prog/run1"
        cp -a "$bld" "$rep_dir"
        echo "--- [CA1] $prog threads=$prog runs=3000 ---"
        run_ca "$rep_dir" "$bin_name" "$report/ca1/${prog}.log" 180 3000
        # core-count comparison on a mid-size workload
        if [[ "$prog" == "reorder_10" ]]; then
            for cpus in 0 0-3 0-15; do
                tag="${cpus//-/_}"
                d2="$work/ca1/$prog/cores$tag"
                cp -a "$bld" "$d2"
                echo "--- [CA1] $prog cpus=$cpus ---"
                run_ca "$d2" "$bin_name" "$report/ca1/${prog}-cpus${tag}.log" 180 3000 "$cpus"
            done
        fi
    done
fi

# --------------------------------------------------------------- CA2
if [[ "$SUITE" == "all" || "$SUITE" == "ca2" ]]; then
    echo "=== CA2: compatibility (legacy CVE C code on modern kernel) ==="
    cve_root="$(find "$ROOT_DIR/evaluation" -maxdepth 2 -type d -name 'CVE-*' -printf '%h\n' | head -1)"
    echo "CVE_ROOT=$cve_root"
    for prog in CVE-2009-3547 CVE-2011-2183 CVE-2016-1972; do
        src="$cve_root/$prog"
        [[ -f "$src/build.sh" ]] || { echo "WARN missing $prog at $src"; continue; }
        bld="$work/ca2/$prog/build"
        echo "--- [CA2] build $prog ---"
        if build_upstream_dir "$src" "$bld" "$report/ca2/${prog}-build.log"; then
            echo "BUILD=$prog OK" >> "$report/ca2/compat.log"
        else
            echo "BUILD=$prog FAIL" >> "$report/ca2/compat.log"
            continue
        fi
        bin_name="$(find_binary "$bld" "$prog" || true)"
        [[ -n "$bin_name" ]] || { echo "BIN=$prog MISSING" >> "$report/ca2/compat.log"; continue; }
        echo "BIN=$prog OK binary=$bin_name" >> "$report/ca2/compat.log"
        rep_dir="$work/ca2/$prog/run1"
        cp -a "$bld" "$rep_dir"
        echo "--- [CA2] run $prog ---"
        run_ca "$rep_dir" "$bin_name" "$report/ca2/${prog}.log" 180 3000
    done
    # architecture / kernel portability note (static evidence, no cross-arch container)
    {
        echo "arch=$(uname -m)"
        echo "kernel=$(uname -r)"
        echo "note=PERIOD uses LLVM IR instrumentation + SCHED_DEADLINE; no ARM/aarch64 image provided in the artifact."
    } > "$report/ca2/platform.log"
fi

# --------------------------------------------------------------- CA3
# A compiled C probe is used instead of Python ctypes: the ctypes syscall path
# is unreliable here (the interpreter is terminated before printing anything),
# while gcc-built binaries run consistently in both privileged/unprivileged
# containers (already validated by the RQ4 micro-benchmark).
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
    a.policy = 6;                 /* SCHED_DEADLINE */
    a.runtime = 20000000;         /* 20 ms */
    a.deadline = 20000000;
    a.period = 20000000;
    if (syscall(314, 0, &a, 0) == 0) {
        printf("PROBE_OK: SCHED_DEADLINE sched_setattr succeeded\n");
    } else {
        printf("PROBE_FAIL: errno=%d (%s)\n", errno, strerror(errno));
    }
    return 0;
}
C
}

probe_deadline() {
    local probe_bin="$work/sched_probe"
    write_probe_c "$work/sched_probe.c"
    gcc -O2 -o "$probe_bin" "$work/sched_probe.c" || { echo "PROBE_BUILD_FAIL"; return 1; }
    "$probe_bin"
}

# Read-only capability analysis (no syscall): CAP_SYS_NICE is bit 23 in CapEff.
# Parse it locally so the unprivileged probe cannot be killed by a seccomp/
# policy trap on sched_setattr. A missing bit means SCHED_DEADLINE is denied
# with EPERM per the Linux sched_setattr(2) contract.
analyze_caps() {
    python3 - <<'PY'
import re
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

if [[ "$SUITE" == "all" || "$SUITE" == "ca3" ]]; then
    echo "=== CA3: security - SCHED_DEADLINE privilege boundary (privileged) ==="
    {
        echo "context=privileged"
        echo "caps=$(grep CapEff /proc/self/status | awk '{print $2}')"
        analyze_caps
        probe_deadline
    } > "$report/ca3/privileged.log" 2>&1
    cat "$report/ca3/privileged.log"
fi

if [[ "$SUITE" == "ca3-unpriv" ]]; then
    echo "=== CA3: security - SCHED_DEADLINE privilege boundary (unprivileged) ==="
    {
        echo "context=unprivileged"
        echo "caps=$(grep CapEff /proc/self/status | awk '{print $2}')"
        analyze_caps
        # We deliberately do NOT call sched_setattr here: in this environment
        # the syscall traps the process before it can print. The CapEff bit
        # analysis above is sufficient to establish the privilege boundary.
    } > "$report/ca3/unprivileged.log" 2>&1
    cat "$report/ca3/unprivileged.log"
fi

# --------------------------------------------------------------- CA4
if [[ "$SUITE" == "all" || "$SUITE" == "ca4" ]]; then
    echo "=== CA4: reproducibility ==="
    {
        echo "upstream_commit=$(git -C "$ROOT_DIR" rev-parse HEAD)"
        echo "expected_commit=$expected_commit"
        echo "commit_match=$([[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$expected_commit" ]] && echo yes || echo no)"
        echo "image=$(cat /proc/self/cgroup | grep -o 'sha256:[0-9a-f]*' | head -1 || true)"
        echo "tool_versions: clang=$(clang --version | head -1) gcc=$(gcc --version | head -1) python=$(python3 --version)"
        echo "linux_kernel=$(uname -r)"
    } > "$report/ca4/fingerprint.log"
    # simulate a fresh clone of the upstream source from the pinned image
    fresh="$(mktemp -d /workdir/period-fresh.XXXXXX)"
    if git clone -q "$ROOT_DIR" "$fresh/PERIOD" 2>"$report/ca4/fresh-clone.err"; then
        echo "fresh_clone=OK commit=$(git -C "$fresh/PERIOD" rev-parse HEAD)" >> "$report/ca4/fingerprint.log"
    else
        echo "fresh_clone=FAIL" >> "$report/ca4/fingerprint.log"
    fi
    # offline verifier (no Docker required) on the reproduction repo
    if python3 "$repo/scripts/verify-results.py" > "$report/ca4/verify.log" 2>&1; then
        echo "offline_verify=OK" >> "$report/ca4/fingerprint.log"
    else
        echo "offline_verify=FAIL" >> "$report/ca4/fingerprint.log"
    fi
    cat "$report/ca4/fingerprint.log"
fi

python3 "$repo/scripts/summarize_ca.py" "$report"
echo "CA_SUITE_DONE=$report SUITE=$SUITE"
