#!/usr/bin/env bash
# tests/routepar_ac7_lane_status_parity_line.sh — PRD-build-gate-route-
# parity-ledger AC7 (P1): "Given 24 h of journal with routed runs, When
# lane-status.sh runs, Then it prints the burst gate parity line with the
# worst producer named." Reuses the exact fixture journal shape AC3
# already proved gate-status.sh --parity aggregates correctly — this test
# only has to prove lane-status.sh's own `report` wires that call through
# and prints the summary line, timestamped inside the last 24h so
# --since picks it up.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
LANE_STATUS="$SKILL_DIR/scripts/lane-status.sh"
[ -x "$LANE_STATUS" ] || { echo "selftest: $LANE_STATUS not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/routepar-ac7-selftest.XXXXXX")"
trap '[ -n "${ROUTEPAR_AC7_KEEP:-}" ] || rm -rf "$T"' EXIT

JDIR="$T/journal"
PRD_DIR="$T/prds"
mkdir -p "$JDIR" "$PRD_DIR/build-queue"
today="$(date -u +%F)"
# ci-checks blocks 2 of 5 burst runs (0.60 pass_rate); risk-gate is 5/5
# on burst (never worst, eligible either way). The summary line's
# runs/pass are summed across every burst producer x route row (this is
# per-producer-invocation, not per-gate-run — the same convention gate-
# parity.py's rows already use elsewhere): risk-gate(5,5) + ci-checks(5,3)
# = 10 runs, 8 pass.
{
  printf '%sT01:00:00Z  gate  widget  pass  (head=a base=v1 gate: head=a pass=25 block=0 verdict=pass blocking=none wall=10s phases=risk-gate:1,ci-checks:2 lock_wait=0s cargo=burst:2/local:0 routed=2/2 route=burst:9)\n' "$today"
  printf '%sT02:00:00Z  gate  widget  pass  (head=b base=v1 gate: head=b pass=25 block=0 verdict=pass blocking=none wall=10s phases=risk-gate:1,ci-checks:2 lock_wait=0s cargo=burst:2/local:0 routed=2/2 route=burst:9)\n' "$today"
  printf '%sT03:00:00Z  gate  widget  block  (head=c base=v1 gate: head=c pass=24 block=1 verdict=block blocking=ci-checks@burst:9 wall=10s phases=risk-gate:1,ci-checks:2! lock_wait=0s cargo=burst:2/local:0 routed=2/2 route=burst:9)\n' "$today"
  printf '%sT04:00:00Z  gate  widget  block  (head=d base=v1 gate: head=d pass=24 block=1 verdict=block blocking=ci-checks@burst:9 wall=10s phases=risk-gate:1,ci-checks:2! lock_wait=0s cargo=burst:2/local:0 routed=2/2 route=burst:9)\n' "$today"
  printf '%sT05:00:00Z  gate  widget  pass  (head=e base=v1 gate: head=e pass=25 block=0 verdict=pass blocking=none wall=10s phases=risk-gate:1,ci-checks:2 lock_wait=0s cargo=burst:2/local:0 routed=2/2 route=burst:9)\n' "$today"
} > "$JDIR/$today.md"

echo "=== AC7: lane-status.sh report prints the burst gate parity line ==="
out="$(BUILD_STATE_DIR="$T/state" bash "$LANE_STATUS" report --prd-dir "$PRD_DIR" --journal-dir "$JDIR" --days 1 2>&1)"
rc=$?
expect "AC7: lane-status.sh report exits 0" "[ $rc -eq 0 ]"
expect "AC7: report has a 'burst gate parity' section" "[[ '$out' == *'burst gate parity'* ]]"
expect "AC7: the line names 10 runs, 8 pass (summed across risk-gate + ci-checks)" \
  "[[ '$out' == *'burst gate parity: 10 runs, 8 pass'* ]]"
expect "AC7: the line names the worst producer (ci-checks)" "[[ '$out' == *'worst producer=ci-checks'* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "routepar_ac7: ALL PASS"
else
  echo "routepar_ac7: assertion(s) FAILED"
fi
exit "$fail"
