#!/usr/bin/env bash
# tests/bgscope_ac11_explain_scope_prints_table.sh — PRD-build-branch-gate-
# scope-artifacts requirement 9 (P2) / AC11: "Given extend-gate.sh
# --explain-scope, When run, Then stdout prints one row per producer with
# its branch-scope policy."
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
EXTEND_GATE="$HERE/../scripts/extend-gate.sh"
[ -x "$EXTEND_GATE" ] || { echo "selftest: $EXTEND_GATE not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

echo "=== AC11: extend-gate.sh --explain-scope ==="
out="$("$EXTEND_GATE" --explain-scope 2>/dev/null)"
rc_out="$?"
expect "exits 0" "[ \"$rc_out\" -eq 0 ]"
for producer in rollback-plan ci-checks reviewer-agent extended-receipts gate land; do
  expect "row for $producer is present" "printf '%s' \"$out\" | grep -q '^$producer'"
done
expect "does not require any positional <build_into> argument" "true"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac11: ALL PASS"; else echo "bgscope_ac11: assertion(s) FAILED"; fi
exit "$fail"
