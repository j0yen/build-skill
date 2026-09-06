#!/usr/bin/env bash
# gate_burst_ac10_run_finishes_before_teardown.sh — PRD-build-gate-cloudburst AC10.
#
# Given a remote run in progress at the hour boundary, when it finishes,
# then the run is not killed and teardown happens after completion.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
FAKE="$HERE/fixtures/gate-burst-fake"
[ -x "$GB" ] || { echo "ac10: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac10.XXXXXX")"
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
REPO="$T/repo"; mkdir -p "$REPO"
echo 'sleep 2; mkdir -p target; echo done > target/marker' > "$REPO/gate.sh"

"$GB" run "$REPO" bash gate.sh >"$T/run.out" 2>&1 &
run_pid=$!
sleep 0.5   # let the run actually start and take the flock

start=$(date +%s)
"$GB" down >"$T/down.out" 2>&1
elapsed=$(( $(date +%s) - start ))

wait "$run_pid"; run_rc=$?

expect "down blocked for roughly the run's remaining sleep (>=1s)" "[ $elapsed -ge 1 ]"
expect "the run itself completed successfully (not killed)"       "[ $run_rc -eq 0 ]"
expect "the run's own output landed (never truncated mid-flight)"  "[ -f \"$REPO/target/marker\" ]"
expect "teardown happened (destroyed) after the run finished"     "grep -q '^destroyed:' \"$T/down.out\""

exit $fail
