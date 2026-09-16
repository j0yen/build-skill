#!/usr/bin/env bash
# tests/bgscope_ac5_correct_branch_pass_deferred.sh — PRD-build-branch-
# gate-scope-artifacts requirement 4 (P0) / AC5: "Given a correct branch,
# When the branch gate completes, Then verdict is pass, the journal line
# contains deferred=rollback-plan,ci-checks (or the subset actually
# deferred), and last-verdict.json.deferred_receipts lists them." Reuses
# the shared "correct branch" run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

echo "=== AC5: a correct branch -> pass, deferred=ci-checks, last-verdict.json.deferred_receipts ==="
DIR="$(bgscope_ensure_shared_run correct)"
echo "  shared run dir: $DIR"
[ -f "$DIR/RC" ] || { echo "selftest: shared correct run never completed" >&2; exit 2; }
rc="$(cat "$DIR/RC")"
expect "extend-gate.sh exited 0 (pass)" "[ \"$rc\" -eq 0 ]"

line="$(grep '  gate  ' "$DIR/journal.md" 2>/dev/null | grep -v reviewer-skipped | head -1 || true)"
echo "  journal: $line"
expect "journal line's outcome is pass" "printf '%s' \"$line\" | grep -q '  pass  (scope=branch'"
expect "journal line names deferred=ci-checks" "printf '%s' \"$line\" | grep -q 'deferred=ci-checks'"

target="$(cat "$DIR/TARGET")"
verdict_json="$target/autobuilder/last-verdict.json"
expect "last-verdict.json exists" "[ -f \"$verdict_json\" ]"
deferred="$(jq -c '.deferred_receipts // []' "$verdict_json" 2>/dev/null || echo '[]')"
echo "  deferred_receipts: $deferred"
deferred_matches=false
[ "$deferred" = '["ci-checks"]' ] && deferred_matches=true
expect "last-verdict.json.deferred_receipts == [\"ci-checks\"]" "[ \"$deferred_matches\" = true ]"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac5: ALL PASS"; else echo "bgscope_ac5: assertion(s) FAILED"; fi
exit "$fail"
