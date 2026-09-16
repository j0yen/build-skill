#!/usr/bin/env bash
# repohealth_ac7_banner_omits_resolved.sh — PRD-build-repo-health-invariants AC7.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/repo-health-selftest.sh" ac7 2>&1)"; rc=$?
echo "$out"
[ "$rc" -eq 0 ] || { echo "FAIL: repo-health-selftest.sh ac7 exited $rc" >&2; exit 1; }
