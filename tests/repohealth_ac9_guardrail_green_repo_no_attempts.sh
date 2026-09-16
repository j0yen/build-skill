#!/usr/bin/env bash
# repohealth_ac9_guardrail_green_repo_no_attempts.sh — PRD-build-repo-health-invariants AC9.
# Thin wrapper around scripts/repo-health-selftest.sh's real assertions
# (same pattern as tests/fixtures/burst-lane-ac-common.sh's
# run_suite_and_expect_labels: one real suite, per-AC wrappers for
# traceability and independent re-run).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/repo-health-selftest.sh" ac9 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: repo-health-selftest.sh ac9 exited $rc" >&2; exit 1; }
