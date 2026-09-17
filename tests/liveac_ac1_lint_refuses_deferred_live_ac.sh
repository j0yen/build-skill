#!/usr/bin/env bash
# liveac_ac1_lint_refuses_deferred_live_ac.sh — PRD-build-live-ac-no-defer AC1.
#
# Given a fixture loop-tooling PRD with AC 3 marked `(Live` and
# `deferred_acs: [3]`, When `prd-lint.sh` runs, Then it exits non-zero with
# `live-ac-deferred` naming AC 3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/live-ac-selftest.sh"

out="$(bash "$SUITE" 2>&1)"; rc=$?

fail=0
for label in \
  "PASS  AC1: live-ac-deferred fires when a loop-tooling PRD defers its (Live AC" \
  "PASS  AC1: prd-lint.sh exits non-zero on the deferred (Live AC"
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
