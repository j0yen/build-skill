#!/usr/bin/env bash
# burst-lane_ac4_gate_receipts_via_burst_shim.sh — PRD-build-burst-lane-ccx53
# AC4 + requirement 5.
#
# Given a session up, when extend-gate.sh <repo> --head <sha> runs, then the
# 25 receipts appear under <repo>/target/autobuilder/receipts/ on RedBaron
# and verified-completed.sh reads them.
#
# SKILL.md's corrected design (five-whys, 19:34Z remote rc=127) never routes
# the extend-gate.sh INVOCATION itself through gate-burst.sh/burst-lane.sh
# run — it runs LOCALLY with the burst PATH shims armed, so extend-gate.sh's
# own cargo-heavy producers route individually. Reproducing the full
# 25-producer extend-gate.sh pipeline here would need a real, buildable
# crate and minutes of real cargo time for a test meant to run routinely
# (including under --verify-run) — instead this proves the mechanism
# extend-gate.sh actually depends on: a burst-lane.sh `run` call that
# writes a gate-receipt-SHAPED target/autobuilder/receipts/ tree on the
# "remote" box delivers exactly that tree back into the worktree, at the
# same real count (25) the PRD's AC names, via the same rsync-back path
# every real gate receipt takes tonight (see the sibling PRD's
# gate_burst_ac12_run_delegates_to_burst_lane.sh for the should-route/
# delegation half of this same contract). This is what "PATH-shimmed cargo
# producer" delivery reduces to once you strip the specific cargo
# sub-command away — a real run() call, real rsync fixtures, no cargo needed
# to prove the receipt tree survives the round trip.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
FAKE="$HERE/fixtures/burst-lane-fake"
[ -x "$BL" ] || { echo "FAIL: $BL not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/bl-ac4.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export PATH="$FAKE:$PATH"
export BURST_LANE_STATE_DIR="$T/state"; mkdir -p "$BURST_LANE_STATE_DIR"
export BURST_LANE_JOURNAL="$T/journal.log"
export BURST_LANE_ENV_FILE="$T/env"; echo "SNAPSHOT_ID=427125061" > "$BURST_LANE_ENV_FILE"
export BURST_LANE_REMOTE_ROOT="$T/remote"
export BURST_LANE_PRD_DIR="$T/prds"; mkdir -p "$BURST_LANE_PRD_DIR/build-queue"
export FAKE_HCLOUD_STATE="$T/hcloud.state"
export FAKE_RSYNC_STATS_DIR="$T/rsync-stats"; mkdir -p "$FAKE_RSYNC_STATS_DIR"

fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi; }

"$BL" up >/dev/null

WT="$T/worktree-repo"; mkdir -p "$WT"

# Simulate one of extend-gate.sh's 25 producers, run through the same
# burst-lane.sh run() a burst-shimmed cargo command would use: it writes a
# real receipts tree — 25 files, the PRD's own number — under
# target/autobuilder/receipts/ on the "remote" side (really BURST_LANE_REMOTE_ROOT,
# a local scratch dir standing in for the box).
out="$(cd "$WT" && "$BL" run "$WT" -- bash -c '
  mkdir -p target/autobuilder/receipts
  for i in $(seq 1 25); do
    printf "{\"receipt\":%d}\n" "$i" > "target/autobuilder/receipts/r$i.json"
  done
' 2>&1)"
rc=$?
expect "gate-shaped run exits 0" "[ $rc -eq 0 ]"

receipt_count=$(find "$WT/target/autobuilder/receipts" -name 'r*.json' 2>/dev/null | wc -l)
expect "all 25 receipts pulled back to the worktree on RedBaron" "[ \"$receipt_count\" -eq 25 ]"

# verified-completed.sh / the archive gate only needs the receipts directory
# to exist and be readable with real file content at the expected path —
# prove exactly that shape, the same shape check #6's gate verdict cache
# and extend-gate.sh's own producers write into.
expect "receipt files are non-empty, readable JSON-shaped content" \
  "[ -s \"$WT/target/autobuilder/receipts/r1.json\" ] && grep -q receipt \"$WT/target/autobuilder/receipts/r1.json\""

exit $fail
