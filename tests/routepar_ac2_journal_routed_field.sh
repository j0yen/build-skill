#!/usr/bin/env bash
# tests/routepar_ac2_journal_routed_field.sh — PRD-build-gate-route-
# parity-ledger AC2: "Given the same run, When the tick journal gate line
# is written, Then it contains routed=<n>/25 and each blocking producer
# carries @<route>, and gate-status.sh <slug> and lane-status.sh still
# parse the line (selftest asserts unchanged output for the pre-existing
# fields)."
#
# gate-status.sh <slug> never reads the journal at all (it reads a
# gate-inflight marker + systemd), so "unaffected" for it is trivial —
# asserted directly. lane-status.sh's own journal reader
# (branch_gates_stats) greps the literal `(scope=branch ` substring
# immediately after the opening paren; this test proves that substring
# still matches byte-for-byte with routed=/route= appended at the end.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/routepar-common.sh"
GATE_STATUS="$ROUTEPAR_REPO_ROOT/scripts/gate-status.sh"
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/routepar-ac2-selftest.XXXXXX")"
trap '[ -n "${ROUTEPAR_AC2_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
routepar_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"
export FAKE_GH_AUTH_RC=0

echo "=== AC2a: a passing run's gate line carries routed=<n>/<receipts> and route=local ==="
out_pass="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_pass=$?
line_pass="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC2a: extend-gate.sh exits 0" "[ $rc_pass -eq 0 ]"
expect "AC2a: gate line carries routed=<n>/<n>" "[[ '$line_pass' =~ routed=[0-9]+/[0-9]+ ]]"
expect "AC2a: gate line carries route=local" "[[ '$line_pass' == *' route=local)'* ]]"
expect "AC2a: pre-existing cargo= field is still present, unmoved before routed=" \
  "[[ '$line_pass' =~ cargo=burst:[0-9]+/local:[0-9]+\ routed= ]]"

echo "=== AC2b: a blocking run's blocking= field suffixes each name with @<route> ==="
export FAKE_VTI_PLAN_RC=1
out_block="$(routepar_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_VTI_PLAN_RC
line_block="$(grep '  gate  ' "$JOURNAL" | tail -1)"
expect "AC2b: gate line's blocking= field names vti-plan@local" "[[ '$line_block' == *'blocking=vti-plan@local'* ]]"
expect "AC2b: gate line still carries route=local" "[[ '$line_block' == *' route=local)'* ]]"

echo "=== AC2c: gate-status.sh <slug> is unaffected (it never reads the journal) ==="
slug_out="$("$GATE_STATUS" no-such-slug-routepar-ac2 2>&1)"
expect "AC2c: gate-status.sh <slug> still returns 'none' for an unknown slug" "[ '$slug_out' = 'none' ]"

echo "=== AC2d: lane-status.sh's own journal grep (scope=branch anchor) is unaffected ==="
BRANCH_JOURNAL="$T/branch-journal.md"
: > "$BRANCH_JOURNAL"
out_branch="$(routepar_run_gate "$REPO" "$BRANCH_JOURNAL" --scope branch --slug routepar-ac2-fixture 2>&1)"
line_branch_pass_count="$(grep -c '  gate  .*  pass  (scope=branch ' "$BRANCH_JOURNAL" || true)"
expect "AC2d: '(scope=branch ' anchor (lane-status.sh's branch_gates_stats) still matches with routed=/route= appended" \
  "[ '${line_branch_pass_count:-0}' -ge 1 ]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "routepar_ac2: ALL PASS"
else
  echo "routepar_ac2: assertion(s) FAILED"
fi
exit "$fail"
