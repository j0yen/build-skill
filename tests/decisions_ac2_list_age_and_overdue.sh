#!/usr/bin/env bash
# decisions_ac2_list_age_and_overdue.sh — PRD-build-open-decision-escalation AC2.
# Thin wrapper around scripts/decisions-selftest.sh's real assertions
# (same pattern as tests/repohealth_ac*.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/decisions-selftest.sh" ac2 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: decisions-selftest.sh ac2 exited $rc" >&2; exit 1; }
