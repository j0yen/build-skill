#!/usr/bin/env bash
# cargoshim_ac8_lane_status_counts_recursion_refused.sh — AC8,
# PRD-build-cargo-shim-recursion-guard requirement 7 (P2): "Given three
# recursion-refused lines today, When lane-status.sh report runs, Then it
# prints shim-recursion-refused=3." Also proves a line older than 24h
# doesn't count, and a line from a day this run isn't scanning stays
# excluded too (the counter isn't just grepping every file it finds).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
LANE_STATUS="$SKILL_DIR/scripts/lane-status.sh"
[ -x "$LANE_STATUS" ] || { echo "ac8: $LANE_STATUS not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/cargoshim-ac8.XXXXXX")"
trap 'rm -rf "$T"' EXIT

JDIR="$T/journal"
PRD_DIR="$T/prds"
mkdir -p "$JDIR" "$PRD_DIR/build-queue"
today="$(date -u +%F)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stale_iso="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ)"

{
  printf '%s  cargo-shim  recursion-refused (depth=2 path=/a)\n' "$now_iso"
  printf '%s  cargo-shim  recursion-refused (depth=2 path=/b)\n' "$now_iso"
  printf '%s  cargo-shim  recursion-refused (depth=3 path=/c)\n' "$now_iso"
  printf '%s  gate  widget  pass  (head=a base=v1 gate: pass=25 block=0)\n' "$now_iso"
} > "$JDIR/$today.md"

# A stale line more than 24h old, filed under an old day's journal --
# must not be counted even though this test's --days window could in
# principle reach back further.
stale_day="$(date -u -d '-3 days' +%F 2>/dev/null || date -u -v-3d +%F)"
printf '%s  cargo-shim  recursion-refused (depth=2 path=/stale)\n' "$stale_iso" > "$JDIR/$stale_day.md"

echo "=== AC8: lane-status.sh report counts today's recursion-refused lines ==="
out="$(BUILD_STATE_DIR="$T/state" bash "$LANE_STATUS" report --prd-dir "$PRD_DIR" --journal-dir "$JDIR" --days 1 2>&1)"
rc=$?
expect "AC8: lane-status.sh report exits 0" "[ $rc -eq 0 ]"
expect "AC8: has a shim recursion guard section" "[[ '$out' == *'shim recursion guard'* ]]"
expect "AC8: prints shim-recursion-refused=3" "[[ '$out' == *'shim-recursion-refused=3'* ]]"
expect "AC8: does not roll the 3-day-stale line into the count" "[[ '$out' != *'shim-recursion-refused=4'* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "cargoshim_ac8: ALL PASS"
else
  echo "cargoshim_ac8: assertion(s) FAILED"
fi
exit "$fail"
