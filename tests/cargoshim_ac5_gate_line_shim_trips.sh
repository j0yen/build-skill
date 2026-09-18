#!/usr/bin/env bash
# tests/cargoshim_ac5_gate_line_shim_trips.sh — PRD-build-cargo-shim-
# recursion-guard AC5 (as amended by the 2026-09-18T14:50Z operator note,
# decision e681d25e):
#
#   "Given the fix landed on RedBaron, When the next gate whose PATH
#    carries both shims runs its cargo steps, Then the gate summary journal
#    line carries shim_trips=<n> (the guard's own trip counter for that
#    run) and the gate completes normally with no `shim re-exec` verdict."
#
# The LIVE half of AC5 (pairing the token on burst-lane-gate-debt-2b2982e's
# next real gate line) cannot be manufactured here and is not attempted —
# this test proves the emitter itself: the token is always present, it
# reads 0 on a gate where no shim ever refused a frame, and it counts real
# refusals written by the production shim (scripts/cargo-budget-bin/cargo)
# into the gate's own exported $WM_CARGO_SHIM_TRIP_LOG. It also pins the
# token's POSITION, because the two pre-existing anchors on that line
# (`cargo=burst:N/local:N routed=` adjacency, and `route=<v>)` as the last
# field inside the paren — both asserted by routepar_ac2) must survive.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
source "$HERE/fixtures/routepar-common.sh"
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/cargoshim-ac5.XXXXXX")"
trap '[ -n "${CARGOSHIM_AC5_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
routepar_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"
export FAKE_GH_AUTH_RC=0
# Never let a trip in this test touch the real build journal.
export CARGO_BUDGET_JOURNAL="$T/shim-journal.md"

echo "=== AC5a: a clean gate's summary line positively attests shim_trips=0 ==="
routepar_run_gate "$REPO" "$JOURNAL" >"$T/clean.out" 2>&1
rc_clean=$?
line_clean="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC5a: extend-gate.sh exits 0 (gate completes normally)" "[ $rc_clean -eq 0 ]"
expect "AC5a: gate summary line carries shim_trips=0" "[[ '$line_clean' == *' shim_trips=0 '* ]]"
expect "AC5a: no shim ever journaled recursion-refused" \
  "! grep -q 'recursion-refused' '$CARGO_BUDGET_JOURNAL' 2>/dev/null"
expect "AC5a: no 'shim re-exec' verdict anywhere in the gate output" \
  "! grep -q 'shim re-exec' '$T/clean.out'"
echo "  line: $line_clean"

echo "=== AC5b: the token's position keeps both pre-existing anchors intact ==="
expect "AC5b: cargo=burst:N/local:N is still immediately followed by routed=" \
  "[[ '$line_clean' =~ cargo=burst:[0-9]+/local:[0-9]+\ routed= ]]"
expect "AC5b: route=<v> is still the last field inside the paren" \
  "[[ '$line_clean' == *' route=local)'* ]]"
expect "AC5b: shim_trips sits between routed= and route=" \
  "[[ '$line_clean' =~ routed=[0-9]+/[0-9]+\ shim_trips=[0-9]+\ route= ]]"

echo "=== AC5c: real refusals by the production shim are counted, per-gate ==="
export FAKE_SHIM_TRIPS=3
routepar_run_gate "$REPO" "$JOURNAL" >"$T/tripped.out" 2>&1
rc_trip=$?
unset FAKE_SHIM_TRIPS
line_trip="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC5c: the gate still completes normally (the counter never blocks)" "[ $rc_trip -eq 0 ]"
expect "AC5c: gate summary line carries shim_trips=3" "[[ '$line_trip' == *' shim_trips=3 '* ]]"
expect "AC5c: those 3 lines were written by the production shim itself" \
  "[ \"\$(grep -c 'cargo-budget-bin' '$REPO/target/autobuilder/shim-trips.log' 2>/dev/null || echo 0)\" = 3 ]"
expect "AC5c: the refusals also reached the shim's own journal" \
  "[ \"\$(grep -c 'recursion-refused' '$CARGO_BUDGET_JOURNAL' 2>/dev/null || echo 0)\" = 3 ]"
echo "  line: $line_trip"

echo "=== AC5d: the count is per-gate — the next gate starts back at 0 ==="
routepar_run_gate "$REPO" "$JOURNAL" >"$T/after.out" 2>&1
line_after="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC5d: the following gate's line reads shim_trips=0, not 3" "[[ '$line_after' == *' shim_trips=0 '* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "cargoshim_ac5: ALL PASS"
else
  echo "cargoshim_ac5: assertion(s) FAILED"
fi
exit "$fail"
