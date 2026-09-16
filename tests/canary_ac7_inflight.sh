#!/usr/bin/env bash
# tests/canary_ac7_inflight.sh — PRD-build-burst-gate-canary-invariant AC7:
# a canary in flight refuses a second concurrent canary with cause=inflight
# within 1s. Exercises the exact flock guard cmd_canary itself takes
# (BOX_STATE_DIR/canary.inflight.lock) by holding it from a background
# subshell first, rather than racing two real cmd_canary invocations
# against a real repo (which would need gh/gate-launch.sh for real).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BL="$HERE/../scripts/burst-lane.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/canary-ac7.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

export PATH="$HERE/fixtures/burst-lane-fake:$PATH"
export BURST_LANE_TEST=1
export BURST_LANE_STATE_DIR="$ROOT/state"
mkdir -p "$BURST_LANE_STATE_DIR/current"
export BURST_LANE_JOURNAL="$ROOT/journal.log"
export BURST_ISOLATION_LIVE_JOURNAL="$BURST_LANE_JOURNAL"

lockfile="$BURST_LANE_STATE_DIR/current/canary.inflight.lock"

( exec {fd}>"$lockfile"; flock "$fd"; sleep 5 ) &
holder=$!
# Give the holder a moment to actually acquire the lock before racing it —
# best-effort, not itself part of the <1s assertion below.
sleep 0.3

echo "== AC7: second canary refuses cause=inflight within 1s =="
start=$(date +%s.%N)
set +e
# --head bypasses gh/CI lookup entirely — this test is only about the
# inflight guard, which runs before head resolution.
out="$("$BL" canary --head deadbeef 2>&1)"; rc=$?
set -e
end=$(date +%s.%N)
elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e-s}')

kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

[ "$rc" -eq 3 ] || { echo "FAIL: expected exit 3, got $rc: $out"; exit 1; }
echo "$out" | grep -q "cause=inflight" || { echo "FAIL: missing cause=inflight: $out"; exit 1; }
awk -v e="$elapsed" 'BEGIN{exit !(e < 1.0)}' || { echo "FAIL: took ${elapsed}s, expected <1s"; exit 1; }
echo "ok (elapsed=${elapsed}s)"
