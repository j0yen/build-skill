#!/usr/bin/env bash
# gate_burst_ac1_mixed_tick_routes.sh — PRD-build-gate-cloudburst AC1.
#
# Given a tick dispatching a Rust gate and a Python suite, when the gate
# step runs, then its cargo executes on the burst box and the journal
# records the routed run.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac1: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac1.XXXXXX")"
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

out=$("$GB" should-route --rust 1 --python 1); rc=$?
expect "mixed tick predicate routes to burst (exit 0)" "[ $rc -eq 0 ]"
expect "predicate names both counts"                  "grep -q 'route: mixed tick' <<<\"\$out\""

REPO="$T/repo"; mkdir -p "$REPO"
echo 'mkdir -p target && echo receipt > target/gate.receipt' > "$REPO/gate.sh"
"$GB" run "$REPO" bash gate.sh >/dev/null; run_rc=$?
expect "gate cargo executes on the burst box (exit 0)" "[ $run_rc -eq 0 ]"
expect "receipt synced back from the box"              "[ -f \"$REPO/target/gate.receipt\" ]"
expect "journal records the routed run"                "grep -q 'gate-burst  run  routed' \"$GATE_BURST_JOURNAL\""

exit $fail
