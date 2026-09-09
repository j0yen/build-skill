#!/usr/bin/env bash
# gate_burst_ac12_run_delegates_to_burst_lane.sh — PRD-build-burst-lane-ccx53
# requirement 5, second half: the PRD's own engineering target says
# gate-burst.sh's "run path [is] pointed at the same session" burst-lane.sh
# owns — not a second, independently-booted gate-burst box. The account's
# 32-core Hetzner limit means there is only ever room for one ccx53
# (non-goal: "A second concurrent burst box").
#
# Given a burst-lane.sh session is already up, when gate-burst.sh run
# executes, then: it delegates to burst-lane.sh's own run (same rsync-up /
# remote-exec / rsync-down machinery, same box), the exit code and
# target/ artifacts come back exactly as burst-lane.sh run alone would
# produce, and gate-burst.sh never calls `hcloud server create` a second
# time (no second box, ever).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GB="$HERE/../scripts/gate-burst.sh"
BL="$HERE/../scripts/burst-lane.sh"
FAKE="$HERE/fixtures/burst-lane-fake"
[ -x "$GB" ] || { echo "ac12: $GB not executable" >&2; exit 2; }
[ -x "$BL" ] || { echo "ac12: $BL not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gb-ac12.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export PATH="$FAKE:$PATH"
export BURST_LANE_STATE_DIR="$T/burst-lane-state"; mkdir -p "$BURST_LANE_STATE_DIR"
export BURST_LANE_JOURNAL="$T/burst-lane-journal.log"
export BURST_LANE_ENV_FILE="$T/burst-lane-env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
export BURST_LANE_REMOTE_ROOT="$T/remote"
export BURST_LANE_PRD_DIR="$T/prds"; mkdir -p "$BURST_LANE_PRD_DIR/build-queue"
export FAKE_HCLOUD_STATE="$T/hcloud.state"
export FAKE_HCLOUD_CALLLOG="$T/hcloud.calls"; : > "$FAKE_HCLOUD_CALLLOG"
export BURST_LANE_COST_LEDGER="$T/cost.jsonl"

export GATE_BURST_STATE_DIR="$T/gate-burst-state"; mkdir -p "$GATE_BURST_STATE_DIR"
export GATE_BURST_JOURNAL="$T/gate-burst-journal.log"
export GATE_BURST_ENV_FILE="$T/gate-burst-env"; echo "SNAPSHOT_ID=427125061" > "$GATE_BURST_ENV_FILE"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# ---- boot the ONE burst-lane session ---------------------------------------
"$BL" up >/dev/null
create_calls_after_boot="$(grep -c 'server create' "$FAKE_HCLOUD_CALLLOG")"
expect "burst-lane session booted (one create call)" "[ \"$create_calls_after_boot\" -eq 1 ]"

# ---- gate-burst.sh run should now delegate, not boot its own box -----------
REPO="$T/repo"; mkdir -p "$REPO"
echo 'mkdir -p target && echo receipt > target/gate.receipt; exit 5' > "$REPO/gate.sh"

out="$("$GB" run "$REPO" bash gate.sh)"; rc=$?
expect "delegated run propagates the remote exit code" "[ $rc -eq 5 ]"
expect "receipt synced back to the repo's target/"     "[ -f \"$REPO/target/gate.receipt\" ]"
expect "gate-burst journal names the delegation"       "grep -q 'gate-burst  run  routed-via-burst-lane' \"$GATE_BURST_JOURNAL\""
expect "burst-lane's own journal recorded the run too" "grep -q 'burst-lane  run  routed' \"$BURST_LANE_JOURNAL\""

create_calls_after_run="$(grep -c 'server create' "$FAKE_HCLOUD_CALLLOG")"
expect "gate-burst never created a second box" "[ \"$create_calls_after_run\" -eq 1 ]"
expect "gate-burst wrote no state of its own for this run" "[ ! -f \"$GATE_BURST_STATE_DIR/active.json\" ]"

echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="
exit $fail
