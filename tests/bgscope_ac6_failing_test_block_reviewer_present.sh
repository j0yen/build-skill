#!/usr/bin/env bash
# tests/bgscope_ac6_failing_test_block_reviewer_present.sh — PRD-build-
# branch-gate-scope-artifacts requirement 3+4 (P0) / AC6: "Given a branch
# with a failing test, When the branch gate completes, Then verdict is
# block with the test failure as an in-scope block and a reviewer-agent
# receipt present." Reuses the shared "incorrect branch" run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

echo "=== AC6: a real failing cargo test -> block, in-scope, reviewer-agent present ==="
DIR="$(bgscope_ensure_shared_run incorrect)"
echo "  shared run dir: $DIR"
[ -f "$DIR/RC" ] || { echo "selftest: shared incorrect run never completed" >&2; exit 2; }
rc="$(cat "$DIR/RC")"
expect "extend-gate.sh exited non-zero (block)" "[ \"$rc\" -ne 0 ]"

line="$(grep '  gate  ' "$DIR/journal.md" 2>/dev/null | grep -v reviewer-skipped | head -1 || true)"
echo "  journal: $line"
expect "journal line's outcome is block" "printf '%s' \"$line\" | grep -q '  block  (scope=branch'"
expect "the failing test is the in-scope block (proof-receipt)" "printf '%s' \"$line\" | grep -q 'proof-receipt'"

target="$(cat "$DIR/TARGET")"
expect "reviewer-agent.json receipt is present despite the in-scope block" \
  "[ -f \"$target/autobuilder/receipts/reviewer-agent.json\" ]"
expect "no reviewer-skipped journal line was written" "! grep -q 'reviewer-skipped' \"$DIR/journal.md\""

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac6: ALL PASS"; else echo "bgscope_ac6: assertion(s) FAILED"; fi
exit "$fail"
