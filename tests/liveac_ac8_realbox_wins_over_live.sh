#!/usr/bin/env bash
# liveac_ac8_realbox_wins_over_live.sh — PRD-build-live-ac-no-defer AC8.
#
# Given an AC marked both `(Live` and `(Real-box`, When lint and derive
# run, Then the `(Real-box` rule applies (deferrable with justification)
# and no `live-ac-*` diagnostic is emitted. (derive/verified-completed.sh
# side of this AC is a follow-on step -- this test covers the lint side,
# which is what's implemented so far.)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/live-ac-selftest.sh"

out="$(bash "$SUITE" 2>&1)"; rc=$?

label="PASS  AC8: (Live + (Real-box on the same AC, deferred, raises no live-ac-* diagnostic"
if grep -qF "$label" <<<"$out"; then
  echo "ok  $label"
else
  echo "FAIL: expected label missing from live-ac-selftest.sh: $label" >&2
  echo "$out" | tail -20 >&2
  exit 1
fi
[ "$rc" -eq 0 ] || { echo "FAIL: live-ac-selftest.sh exited $rc (other AC(s) regressed)" >&2; echo "$out" | tail -20 >&2; exit 1; }
exit 0
