#!/usr/bin/env bash
# liveac_ac3_product_prd_exempt.sh — PRD-build-live-ac-no-defer AC3.
#
# Given a fixture product PRD (`build_into` outside the loop-tooling list)
# deferring a `(Live` AC, When `prd-lint.sh` runs, Then no `live-ac-*`
# diagnostic is emitted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/live-ac-selftest.sh"

out="$(bash "$SUITE" 2>&1)"; rc=$?

label="PASS  AC3: a product PRD deferring a (Live AC gets no live-ac-* diagnostic"
if grep -qF "$label" <<<"$out"; then
  echo "ok  $label"
else
  echo "FAIL: expected label missing from live-ac-selftest.sh: $label" >&2
  echo "$out" | tail -20 >&2
  exit 1
fi
[ "$rc" -eq 0 ] || { echo "FAIL: live-ac-selftest.sh exited $rc (other AC(s) regressed)" >&2; echo "$out" | tail -20 >&2; exit 1; }
exit 0
