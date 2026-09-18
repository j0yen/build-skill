#!/usr/bin/env bash
# tickout_ac11_loop_line_both_renderers.sh —
# PRD-buildloop-tick-outcome-liveness AC11.
#
# Given a record 20 minutes old, When handoff-header.sh and
# gates-banner.sh run, Then each prints
# `LOOP: last_ok=<age> streak_failed=<n>  [STALE 20m]`; with
# GATES_BANNER_NO_AGE=1 the banner prints the field without the age
# suffix and its remaining output is byte-identical to today's.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HH="$HERE/../scripts/handoff-header.sh"
GB="$HERE/../scripts/gates-banner.sh"
JQ="${JQ:-jq}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STATE="$TMP/state"
mkdir -p "$STATE"
NOW_EPOCH="$(date -u -d '2026-09-18T05:00:00Z' +%s)"
LAST_OK_TS="2026-09-18T04:40:00Z"   # exactly 20 minutes before NOW_EPOCH
"$JQ" -n --arg last_ok "$LAST_OK_TS" \
  '{ts:"2026-09-18T05:00:00Z",n:9,rc:1,outcome:"failed",cause:"other",evidence:"boom",streak_failed:1,last_ok_ts:$last_ok,lane:"redbaron"}' \
  > "$STATE/tick-outcome.json"

fail=0

# --- handoff-header.sh: no gate-red.summary at all, LOOP: line still prints
out_hh="$(BUILD_STATE_DIR="$STATE" GATE_RED_NOW="$NOW_EPOCH" "$HH")"
if printf '%s\n' "$out_hh" | grep -qE '^LOOP: last_ok=1200 streak_failed=1  \[STALE 20m\]$'; then
  echo "ok  AC11: handoff-header.sh prints the LOOP: line, STALE 20m"
else
  echo "FAIL: handoff-header.sh output: $out_hh"
  fail=1
fi

# --- gates-banner.sh: force the RedBaron-local branch, no gate-red.summary
out_gb="$(BUILD_STATE_DIR="$STATE" GATE_RED_NOW="$NOW_EPOCH" GATES_BANNER_HOSTNAME="redbaron" "$GB")"
if printf '%s\n' "$out_gb" | grep -qE '^LOOP: last_ok=1200 streak_failed=1  \[STALE 20m\]$'; then
  echo "ok  AC11: gates-banner.sh prints the LOOP: line, STALE 20m"
else
  echo "FAIL: gates-banner.sh output: $out_gb"
  fail=1
fi

# --- GATES_BANNER_NO_AGE=1: no bracket, and the rest of the output is
# byte-identical to the same call without the LOOP: line's own no-age
# effect isolated (compare against a run where BUILD_STATE_DIR points at
# an empty state dir, i.e. no tick-outcome.json at all -- that's "today's"
# pre-this-PRD output for this same fixture).
out_gb_noage="$(BUILD_STATE_DIR="$STATE" GATE_RED_NOW="$NOW_EPOCH" GATES_BANNER_HOSTNAME="redbaron" GATES_BANNER_NO_AGE=1 "$GB")"
loop_line_noage="$(printf '%s\n' "$out_gb_noage" | grep '^LOOP:' || true)"
if [ "$loop_line_noage" = "LOOP: last_ok=1200 streak_failed=1" ]; then
  echo "ok  AC11: GATES_BANNER_NO_AGE=1 -> LOOP: line has no bracket"
else
  echo "FAIL: no-age LOOP: line = '$loop_line_noage'"
  fail=1
fi

rest_noage="$(printf '%s\n' "$out_gb_noage" | grep -v '^LOOP:')"
rest_baseline="$(BUILD_STATE_DIR="$TMP/empty-state" GATE_RED_NOW="$NOW_EPOCH" GATES_BANNER_HOSTNAME="redbaron" GATES_BANNER_NO_AGE=1 "$GB" | grep -v '^LOOP:')"
if [ "$rest_noage" = "$rest_baseline" ]; then
  echo "ok  AC11: remaining output byte-identical to a run with no tick-outcome.json"
else
  echo "FAIL: remaining output differs:"
  diff <(printf '%s\n' "$rest_noage") <(printf '%s\n' "$rest_baseline") || true
  fail=1
fi

exit "$fail"
