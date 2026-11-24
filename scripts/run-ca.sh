#!/usr/bin/env bash
# Host wrapper for the Critical-Analysis extension suite.
# Runs the privileged suite (CA1/CA2/CA3-priv/CA4) and a separate unprivileged
# container for the CA3 privilege-boundary probe. Same pinned author image.
set -Eeuo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image='wcventure/period@sha256:8f47d8b9148f2db579627842026e722d0f205ddeab13e70ee41a8df3dbd59fbc'

command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
test "$(uname -m)" = x86_64 || { echo "Use an x86_64 Linux/WSL2 host." >&2; exit 1; }
docker info >/dev/null

if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker pull "$image"
fi

mkdir -p "$repo/results"
run_id="ca-$(date -u +%Y%m%dT%H%M%SZ)-$$"
report="$repo/results/$run_id"
mkdir -p "$report/ca3"

echo "CA run id: $run_id"

# privileged suite
docker run --rm --privileged --network none \
    --mount "type=bind,source=$repo,target=/repro" \
    --workdir /repro \
    --env "CA_REPORT=/repro/results/$run_id" \
    "$image" bash /repro/scripts/ca_suite.sh "$@"

# unprivileged container: only the CA3 security probe
docker run --rm --network none \
    --mount "type=bind,source=$repo,target=/repro" \
    --workdir /repro \
    --env "CA_REPORT=/repro/results/$run_id" \
    "$image" bash /repro/scripts/ca_suite.sh --suite ca3-unpriv

# Re-summarise on the host now that BOTH privilege contexts have written logs
# (the container-side summary runs before the unprivileged container exists).
# Convert the POSIX-style path to a native path for Windows Python (Git Bash).
summarizer="$repo/scripts/summarize_ca.py"
native_report="$report"
native_summarizer="$summarizer"
if command -v cygpath >/dev/null 2>&1; then
    native_report="$(cygpath -w "$report")"
    native_summarizer="$(cygpath -w "$summarizer")"
fi
python3 -B "$native_summarizer" "$native_report"

echo "CA_DONE=$report"
