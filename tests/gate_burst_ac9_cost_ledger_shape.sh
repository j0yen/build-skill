#!/usr/bin/env bash
# gate_burst_ac9_cost_ledger_shape.sh — PRD-build-gate-cloudburst AC9 (P1).
#
# Given a completed burst, when the ledger is read, then it shows date,
# server type, minutes alive, runs served, and estimated cost.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac9: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac9.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export PATH="$FAKE:$PATH"
export GATE_BURST_STATE_DIR="$T/state"; mkdir -p "$GATE_BURST_STATE_DIR"
export GATE_BURST_LEDGER="$T/ledger.ndjson"
export GATE_BURST_JOURNAL="$T/journal.md"
export GATE_BURST_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$GATE_BURST_ENV_FILE"
export GATE_BURST_REMOTE_ROOT="$T/remote"
export FAKE_HCLOUD_STATE="$T/hcloud.state"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

"$GB" up >/dev/null
REPO="$T/repo"; mkdir -p "$REPO"; echo 'mkdir -p target && echo r > target/x' > "$REPO/gate.sh"
"$GB" run "$REPO" bash gate.sh >/dev/null
"$GB" down >/dev/null

line="$(cat "$GATE_BURST_LEDGER")"
IFS=$'\t' read -r ts stype minutes runs cost <<<"$line"
expect "ledger line has a date/timestamp field"      "[[ \"\$ts\" == *T*Z ]]"
expect "ledger line names the server type"            "[ \"\$stype\" = ccx23 ]"
expect "ledger line has a numeric minutes-alive field" "[[ \"\$minutes\" =~ ^[0-9]+\$ ]]"
expect "ledger line has runs_served=1"                "[ \"\$runs\" -eq 1 ]"
expect "ledger line has an estimated cost field"       "[[ \"\$cost\" =~ ^[0-9]+\\.[0-9]+\$ ]]"

# status prints a month-to-date total derived from the ledger.
out=$("$GB" status)
expect "status prints a month-to-date total" "grep -qF 'month-to-date: \$' <<<\"\$out\""

exit $fail
