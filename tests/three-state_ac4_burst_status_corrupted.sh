#!/usr/bin/env bash
# three-state_ac4_burst_status_corrupted.sh — PRD-build-three-state-probes
# AC4.
#
# Given the burst-lane status probe with session.json corrupted, when lane
# code consults it via the retrofit, then the result is could-not-check
# (not no-session/clean) and the caller (gate-burst.sh's should-route,
# which falls back local on anything but a literal "active":true) falls
# back local, with the reason journaled to burst-lane's own log.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
GB="$HERE/../scripts/gate-burst.sh"
[ -x "$BL" ] || { echo "ac4: $BL not executable" >&2; exit 2; }
[ -x "$GB" ] || { echo "ac4: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ts-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export BURST_LANE_STATE_DIR="$T/burst-state"; mkdir -p "$BURST_LANE_STATE_DIR"
export BURST_LANE_JOURNAL="$T/burst-journal.log"
export BUILD_STATE_DIR="$T/probestate"
export PROBE_JOURNAL_DIR="$T/probe-journal"
export GATE_BURST_BURST_LANE_BIN="$BL"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# --- corrupt session.json: exists, but not valid JSON -----------------------
printf 'not { valid json' > "$BURST_LANE_STATE_DIR/session.json"

status_out="$("$BL" status)"
status_json="$("$BL" status --json)"

expect "status prints could-not-check, not 'no active session'" \
  "grep -q 'could-not-check' <<<\"\$status_out\""
expect "status does NOT claim clean 'no active session' prose" \
  "! grep -q '^no active session\$' <<<\"\$status_out\""
expect "json form still says active:false (safe fallback shape)" \
  "grep -q '\"active\":false' <<<\"\$status_json\""
expect "json form flags could_not_check:true" \
  "grep -q 'could_not_check.:true' <<<\"\$status_json\""

ledger="$BUILD_STATE_DIR/probes/ledger.jsonl"
expect "probe ledger recorded could-not-check for burst-status" \
  "grep -q '\"probe\": *\"burst-status\"' '$ledger' && grep -q '\"state\": *\"could-not-check\"' '$ledger'"
expect "burst-lane's own journal names the corruption reason" \
  "grep -q 'session.json corrupted' '$BURST_LANE_JOURNAL'"

# --- the caller (gate-burst.sh should-route) falls back local --------------
route_out="$("$GB" should-route --rust 1 --python 0 2>&1)"; route_rc=$?
expect "should-route falls back local (exit 1) on a corrupted session" "[ $route_rc -eq 1 ]"
expect "should-route's own message says local" "grep -qi '^local:' <<<\"\$route_out\""

exit $fail
