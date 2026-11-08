#!/usr/bin/env bash
set -Eeuo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image='wcventure/period@sha256:8f47d8b9148f2db579627842026e722d0f205ddeab13e70ee41a8df3dbd59fbc'
command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
test "$(uname -m)" = x86_64 || { echo "Use an x86_64 Linux/WSL2 host." >&2; exit 1; }
docker info >/dev/null

# Pulling is needed only once; the test container itself has no network.
if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker pull "$image"
fi
mkdir -p "$repo/results"
docker run --rm --privileged --network none \
    --mount "type=bind,source=$repo,target=/repro" \
    --workdir /repro \
    "$image" bash /repro/scripts/validate.sh
