#!/usr/bin/env bash
# decisions_ac7_remote_unreachable_fails_open.sh — PRD-build-open-decision-escalation AC7.
# Thin wrapper around scripts/decisions-selftest.sh's real assertions
# (same pattern as tests/repohealth_ac*.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/decisions-selftest.sh" ac7 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: decisions-selftest.sh ac7 exited $rc" >&2; exit 1; }
