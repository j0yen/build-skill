#!/usr/bin/env bash
# tests/jsw_ac10_tick_summary_direct_runner.sh — PRD-build-journal-single-writer AC10.
# Thin wrapper around scripts/lint-journal-fixtures-selftest.sh's real
# assertions (same pattern as tests/decisions_ac*.sh / tests/repohealth_ac*.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/lint-journal-fixtures-selftest.sh" ac10 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: lint-journal-fixtures-selftest.sh ac10 exited $rc" >&2; exit 1; }
