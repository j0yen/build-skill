#!/usr/bin/env bash
# gate_burst_ac3_reuse_one_server.sh — PRD-build-gate-cloudburst AC3.
#
# Given a booted box and three pending gate runs in the same tick, when
# they execute, then all three reuse the one server and the ledger shows
# one boot.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac3: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac3.XXXXXX")"
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

REPO="$T/repo"; mkdir -p "$REPO"
echo 'mkdir -p target && echo r >> target/gate.receipt' > "$REPO/gate.sh"

"$GB" up >/dev/null
boot_id_1="$(grep -oE '[0-9]+' "$GATE_BURST_STATE_DIR/active.json" | head -n1)"

for i in 1 2 3; do
  "$GB" run "$REPO" bash gate.sh >/dev/null
done

boot_id_2="$(grep -oE '"server_id":[0-9]+' "$GATE_BURST_STATE_DIR/active.json" | cut -d: -f2)"
runs="$(grep -oE '"runs_served":[0-9]+' "$GATE_BURST_STATE_DIR/active.json" | cut -d: -f2)"
expect "server id unchanged across all three runs" "[ \"$boot_id_1\" = \"$boot_id_2\" ]"
expect "runs_served counted all three"              "[ \"$runs\" -eq 3 ]"

"$GB" down >/dev/null
expect "exactly one ledger line for the whole tick" "[ \"\$(wc -l < \"$GATE_BURST_LEDGER\")\" -eq 1 ]"
expect "ledger line records 3 runs served"          "grep -qE $'\\t3\\t' \"$GATE_BURST_LEDGER\""

exit $fail
