#!/usr/bin/env bash
# repohealth_ac6_ci_status_staleness_never_reads_green.sh — PRD-build-repo-health-invariants AC6.
# Thin wrapper around scripts/repo-health-selftest.sh's real assertions
# (same pattern as tests/fixtures/burst-lane-ac-common.sh's
# run_suite_and_expect_labels: one real suite, per-AC wrappers for
# traceability and independent re-run).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/repo-health-selftest.sh" ac6 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: repo-health-selftest.sh ac6 exited $rc" >&2; exit 1; }
