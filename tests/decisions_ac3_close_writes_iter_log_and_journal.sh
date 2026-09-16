#!/usr/bin/env bash
# decisions_ac3_close_writes_iter_log_and_journal.sh — PRD-build-open-decision-escalation AC3.
# Thin wrapper around scripts/decisions-selftest.sh's real assertions
# (same pattern as tests/repohealth_ac*.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/decisions-selftest.sh" ac3 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: decisions-selftest.sh ac3 exited $rc" >&2; exit 1; }
