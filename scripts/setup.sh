#!/usr/bin/env bash
# Preflight environment check for the PERIOD replication.
# Safe to run on the host: it only reads Docker state and pulls the pinned image.
set -Eeuo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image='wcventure/period@sha256:8f47d8b9148f2db579627842026e722d0f205ddeab13e70ee41a8df3dbd59fbc'
expected_commit='b6f72a7b06d01ffa7114b640312873ec2578a5ea'

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "PASS: $*"; }

echo "== PERIOD replication environment check =="
echo "Repository: $repo"
echo "Pinned image: $image"
echo

command -v docker >/dev/null 2>&1 || fail "Docker is not installed or not on PATH."
ok "docker CLI found: $(docker --version)"

test "$(uname -m)" = x86_64 || fail "x86_64 host required; current arch: $(uname -m)"
ok "host architecture is x86_64"

docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable (is Docker Desktop running?)."
ok "Docker daemon reachable"

if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Pulling pinned image (one time, needs network)..."
    docker pull "$image"
fi
ok "pinned image present locally"

echo "Checking pinned upstream checkout and tool versions inside the image..."
docker run --rm --privileged --network none \
    --mount "type=bind,source=$repo,target=/repro" \
    --workdir /repro \
    "$image" bash -s <<'EOF'
set -Eeuo pipefail
export ROOT_DIR="${ROOT_DIR:-/workdir/PERIOD}"
head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
echo "UPSTREAM_COMMIT=$head"
test "$head" = 'b6f72a7b06d01ffa7114b640312873ec2578a5ea' || {
    echo "FAIL: unexpected upstream commit"; exit 1;
}
python3 - <<'PY'
import ctypes, os, platform
if platform.machine() != "x86_64":
    raise RuntimeError("sched_setattr probe needs x86_64")
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
echo "--- tool versions ---"
cat /etc/os-release | head -3
clang --version | head -1
gcc --version | head -1
python3 --version
python3 -c 'import numpy, sysv_ipc; print("numpy", numpy.__version__); print("sysv_ipc", sysv_ipc.__version__)'
nproc
EOF

echo
ok "environment is ready; next: make validate, then make experiments"
