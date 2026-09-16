#!/usr/bin/env bash
# tests/routepar_ac1_receipt_route_stamp.sh — PRD-build-gate-route-
# parity-ledger AC1: "Given a gate run with BURST_LANE=1 and a live
# session, When extend-gate.sh finishes, Then every producer receipt JSON
# has "route": "burst:<server_id>" for producers that invoked cargo
# through the shim and "local" for the rest. Given no burst session,
# every producer's receipt reads "route": "local"."
#
# Drives the REAL extend-gate.sh through the fake toolchain at
# tests/fixtures/routepar-fake/ (never mcphost, never a real box) against
# ONE disposable fixture crate, once with no burst policy configured
# (route must land "local" everywhere) and once with BUILD_BURST_ENABLED=1
# + BURST_LANE=1 + a canned CARGO_ROUTE_STATUS_JSON (route must land
# "burst:<id>" everywhere) — cargo_route_current()'s own env-seam
# (scripts/lib/cargo-route.sh), so this proves the real gate wiring
# without a real box or a real cargo compile.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/routepar-common.sh"
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/routepar-ac1-selftest.XXXXXX")"
trap '[ -n "${ROUTEPAR_AC1_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
routepar_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

# gh "authenticated" so ci-checks actually runs (an unauthenticated gh
# skips ci-checks AND note_blocks "gh not authenticated", which would
# non-emptily arm the quota guard at scope=main and skip reviewer too —
# unrelated to what THIS test asserts, so route it out of the way).
export FAKE_GH_AUTH_RC=0

echo "=== AC1a: no burst policy configured -> every producer receipt reads route=local ==="
out_local="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_local=$?
expect "AC1a: extend-gate.sh exits 0" "[ $rc_local -eq 0 ]"
for name in intake vti-plan proof-receipt rollback-plan ci-checks fake-producer-a fake-producer-b reviewer-agent; do
  route="$(routepar_receipt_route "$REPO" "$name")"
  expect "AC1a: $name.json route=local (got '$route')" "[ '$route' = 'local' ]"
done

echo "=== AC1b: BURST_LANE=1 + a live session -> every producer receipt reads route=burst:<id> ==="
export BUILD_BURST_ENABLED=1
export BURST_LANE=1
export CARGO_ROUTE_STATUS_JSON='{"active":true,"server_id":"166121325"}'
out_burst="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_burst=$?
unset BUILD_BURST_ENABLED BURST_LANE CARGO_ROUTE_STATUS_JSON
expect "AC1b: extend-gate.sh exits 0" "[ $rc_burst -eq 0 ]"
for name in intake vti-plan proof-receipt rollback-plan ci-checks fake-producer-a fake-producer-b reviewer-agent; do
  route="$(routepar_receipt_route "$REPO" "$name")"
  expect "AC1b: $name.json route=burst:166121325 (got '$route')" "[ '$route' = 'burst:166121325' ]"
done

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "routepar_ac1: ALL PASS"
else
  echo "routepar_ac1: assertion(s) FAILED"
fi
exit "$fail"
