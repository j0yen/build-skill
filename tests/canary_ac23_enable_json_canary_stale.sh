#!/usr/bin/env bash
# tests/canary_ac23_enable_json_canary_stale.sh —
# PRD-build-burst-gate-canary-invariant R17/AC23.
#
# AC23 (enable.json whose canary_ts is 25 h old -> knob alarm with
# cause=canary-stale, routing off for that tick) is asserted inside
# tests/canary_ac21_ac23_select_tick_knob_alarm.sh, where it shares one
# select-tick.sh fixture with AC21. verified-completed.sh --derive pairs ACs
# by the `<test_prefix>_ac<N>_` filename glob, which matches `canary_ac21_...`
# for AC21 and nothing for AC23 — so AC23 derived as MISSING (2026-09-18)
# despite being covered. A multi-AC filename covers two ACs and pairs one;
# this wrapper is the second pairing surface rather than a second copy of the
# fixture. It RUNS the combined file and fails unless each AC23 label came
# back `ok`, so dropping the AC23 section fails here instead of passing by
# absence.
#
# Pure fixture (inherited): fake burst-lane status, fake alert-deliver on both
# the select-tick and gate-red-tick paths, own journal — no box, no network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
COMBINED="$HERE/canary_ac21_ac23_select_tick_knob_alarm.sh"
[ -f "$COMBINED" ] || { echo "canary_ac23: $COMBINED missing" >&2; exit 2; }

out="$(bash "$COMBINED" 2>&1)"; rc=$?

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

expect "AC23: canary_ac21_ac23_select_tick_knob_alarm.sh exits 0" "[ $rc -eq 0 ]"
expect "AC23: the 25h-stale enable.json case ran at all" \
  "printf '%s' \"\$out\" | grep -qF '=== AC23:'"
expect "AC23: tick exits 0 (alarm is not fatal)" \
  "printf '%s' \"\$out\" | grep -qF 'ok  AC23: exit 0'"
expect "AC23: journal carries cause=canary-stale" \
  "printf '%s' \"\$out\" | grep -qF 'ok  AC23: journal carries cause=canary-stale'"
expect "AC23: routing off for that tick (counts.burst_session forced 0)" \
  "printf '%s' \"\$out\" | grep -qF 'ok  AC23: counts.burst_session forced to 0'"
expect "AC23: no FAIL line anywhere in the combined suite" \
  "! printf '%s' \"\$out\" | grep -q '^FAIL '"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "canary_ac23_enable_json_canary_stale: ALL PASS"
  exit 0
fi
echo "canary_ac23_enable_json_canary_stale: assertion(s) FAILED" >&2
printf '%s\n' "$out" | tail -40 >&2
exit 1
