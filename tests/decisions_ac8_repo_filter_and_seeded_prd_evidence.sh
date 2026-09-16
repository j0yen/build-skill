#!/usr/bin/env bash
# decisions_ac8_repo_filter_and_seeded_prd_evidence.sh — PRD-build-open-decision-escalation requirement 8 (P2).
# Thin wrapper around scripts/decisions-selftest.sh's real assertions
# (same pattern as tests/repohealth_ac*.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/decisions-selftest.sh" ac8 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: decisions-selftest.sh ac8 exited $rc" >&2; exit 1; }
