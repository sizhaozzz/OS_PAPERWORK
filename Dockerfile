# Reproducible harness for the PERIOD replication.
# The scientific environment (compiler, SVF, instrumentation, benchmarks) is the
# authors' pinned image; this file only layers our scripts and workloads on top.
# Build:   docker build -t period-repro:local .
# Run:     docker run --rm --privileged --network none period-repro:local \
#              bash /repro/scripts/validate.sh
FROM wcventure/period@sha256:8f47d8b9148f2db579627842026e722d0f205ddeab13e70ee41a8df3dbd59fbc

LABEL org.opencontainers.image.title="PERIOD replication harness" \
      org.opencontainers.image.description="ICSE 2022 PERIOD reproduction, pinned to author image" \
      org.opencontainers.image.source="https://github.com/sizhaozzz/OS_PAPERWORK"

WORKDIR /repro
COPY scripts /repro/scripts
COPY benchmarks /repro/benchmarks
COPY docs /repro/docs
COPY Makefile /repro/Makefile

RUN chmod +x /repro/scripts/*.sh

CMD ["/bin/bash"]
