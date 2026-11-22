# Convenience entry points for the PERIOD replication.
# The environment is pinned in the author Docker image (see scripts/setup.sh).
.PHONY: help setup validate experiments c1 c2 verify figures extension clean

IMAGE := wcventure/period@sha256:8f47d8b9148f2db579627842026e722d0f205ddeab13e70ee41a8df3dbd59fbc

help:
	@echo "Targets:"
	@echo "  setup        Check Docker/x86_64/SCHED_DEADLINE and pin the image"
	@echo "  validate     Run environment validation (doubleFree + CVE-2016-1972)"
	@echo "  experiments  Run main experiments C1 and C2 (3 repetitions)"
	@echo "  c1 / c2      Run a single claim"
	@echo "  extension    Run the depth-bound extension experiment"
	@echo "  figures      Regenerate PNG charts from archived CSVs (no Docker)"
	@echo "  verify       Verify all archived logs and regenerate results/summary.csv"
	@echo "  clean        Remove local Python caches"

setup:
	bash scripts/setup.sh

validate:
	bash scripts/run-tests.sh

experiments:
	bash scripts/run-experiments.sh --claim all

c1:
	bash scripts/run-experiments.sh --claim c1

c2:
	bash scripts/run-experiments.sh --claim c2

extension:
	bash scripts/run-extension.sh

figures:
	python3 -B scripts/make_figures.py

verify:
	python3 -B scripts/verify-results.py --write-index

clean:
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
	find . -name '*.pyc' -type f -delete
