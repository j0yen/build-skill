#!/usr/bin/env bash
# gate_burst_ac4_idle_hour_teardown.sh — PRD-build-gate-cloudburst AC4.
#
# Given an idle box at minute 55 of its billed hour, when the teardown
# check fires, then the server is destroyed and destroy-verify confirms
# it gone.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac4: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export PATH="$FAKE:$PATH"
export GATE_BURST_STATE_DIR="$T/state"; mkdir -p "$GATE_BURST_STATE_DIR"
export GATE_BURST_LEDGER="$T/ledger.ndjson"
export GATE_BURST_JOURNAL="$T/journal.md"
export GATE_BURST_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$GATE_BURST_ENV_FILE"
export FAKE_HCLOUD_STATE="$T/hcloud.state"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

NOW0=$(date -u +%s)
GATE_BURST_NOW=$NOW0 "$GB" up >/dev/null
id="$(grep -oE '"server_id":[0-9]+' "$GATE_BURST_STATE_DIR/active.json" | cut -d: -f2)"

LATER=$((NOW0 + 55*60))
out=$(GATE_BURST_NOW=$LATER "$GB" down --more-work-queued)
expect "idle box at minute 55 is destroyed despite more-work-queued" "grep -q '^destroyed:' <<<\"\$out\""
expect "destroy-verify confirms the id in the message"               "grep -q \"\$id\" <<<\"\$out\""
expect "hcloud no longer reports the server alive"                   "! \"$FAKE\"/hcloud server describe \"$id\""
expect "state is cleared after a verified destroy"                   "[ ! -f \"$GATE_BURST_STATE_DIR/active.json\" ]"

exit $fail
