#!/usr/bin/env bash
# Host wrapper for the ONE unified extension experiment.
# Runs the whole matrix in one privileged container, then a single
# unprivileged capability probe of the same image, then summarises.
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
run_id="single-$(date -u +%Y%m%dT%H%M%SZ)-$$"
report="$repo/results/$run_id"
mkdir -p "$report/security"

echo "Single extension run id: $run_id"

docker run --rm --privileged --network none \
    --mount "type=bind,source=$repo,target=/repro" \
    --workdir /repro \
    --env "SINGLE_REPORT=/repro/results/$run_id" \
    "$image" bash /repro/scripts/single_suite.sh --mode matrix

docker run --rm --network none \
    --mount "type=bind,source=$repo,target=/repro" \
    --workdir /repro \
    --env "SINGLE_REPORT=/repro/results/$run_id" \
    "$image" bash /repro/scripts/single_suite.sh --mode unpriv

summarizer="$repo/scripts/summarize_single.py"
native_report="$report"
native_summarizer="$summarizer"
if command -v cygpath >/dev/null 2>&1; then
    native_report="$(cygpath -w "$report")"
    native_summarizer="$(cygpath -w "$summarizer")"
fi
python3 -B "$native_summarizer" "$native_report"

echo "SINGLE_DONE=$report"
