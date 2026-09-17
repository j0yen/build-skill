#!/usr/bin/env bash
# liveac_ac2_lint_missing_marker_migration_guard.sh — PRD-build-live-ac-no-defer AC2.
#
# Given a fixture loop-tooling PRD drafted 2026-09-17 with no `(Live` AC,
# When `prd-lint.sh` runs, Then it exits non-zero with `live-ac-missing`;
# the same PRD with `Drafted: 2026-09-01` yields a warning and exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/live-ac-selftest.sh"

out="$(bash "$SUITE" 2>&1)"; rc=$?

fail=0
for label in \
  "PASS  AC2: live-ac-missing fails a loop-tooling PRD drafted 2026-09-17 with no (Live AC" \
  "PASS  AC2: an earlier-drafted PRD with no (Live AC gets a warning, not a failure"
do
  if grep -qF "$label" <<<"$out"; then
    echo "ok  $label"
  else
    echo "FAIL: expected label missing from live-ac-selftest.sh: $label" >&2
    echo "$out" | tail -20 >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1
[ "$rc" -eq 0 ] || { echo "FAIL: live-ac-selftest.sh exited $rc (other AC(s) regressed)" >&2; echo "$out" | tail -20 >&2; exit 1; }
exit 0
