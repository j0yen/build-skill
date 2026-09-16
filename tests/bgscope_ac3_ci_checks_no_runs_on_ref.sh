#!/usr/bin/env bash
# tests/bgscope_ac3_ci_checks_no_runs_on_ref.sh — PRD-build-branch-gate-
# scope-artifacts requirement 2 (P0) / AC3: "Given BRANCH_GATE_PUSH=1 and
# a fixture origin with no CI, When the branch gate runs, Then the branch
# ref exists on origin, and after CI_CHECKS_BRANCH_WAIT the receipt reads
# scope-deferred (no-runs-on-ref)." Reuses the shared "correct branch" run
# (tests/fixtures/bgscope-common.sh) -- building via BUILD_TARGET_ROOT+a
# real bare origin+push is the expensive part, and AC4/AC5/AC6 all read
# facts off the SAME run rather than each paying for their own.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

echo "=== AC3: BRANCH_GATE_PUSH=1 + real bare origin, no CI -> scope-deferred (no-runs-on-ref) ==="
DIR="$(bgscope_ensure_shared_run correct)"
echo "  shared run dir: $DIR"
[ -f "$DIR/RC" ] || { echo "selftest: shared correct run never completed" >&2; exit 2; }
SLUG="$(cat "$DIR/SLUG")"

expect "the branch ref was pushed to origin" \
  "git -C \"$DIR/origin.git\" show-ref --verify --quiet refs/heads/autobuilder/$SLUG"

target="$(cat "$DIR/TARGET")"
ci_receipt="$target/autobuilder/receipts/ci-checks.json"
expect "ci-checks.json receipt exists" "[ -f \"$ci_receipt\" ]"
skip_reason="$(jq -r '.skip_reason // empty' "$ci_receipt" 2>/dev/null || true)"
echo "  ci-checks.json skip_reason: $skip_reason"
expect "receipt reads scope-deferred (no-runs-on-ref)" "printf '%s' \"$skip_reason\" | grep -q '^no-runs-on-ref'"
scope_deferred="$(jq -r '.scope_deferred // false' "$ci_receipt" 2>/dev/null || true)"
expect "receipt's scope_deferred flag is true" "[ \"$scope_deferred\" = true ]"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac3: ALL PASS"; else echo "bgscope_ac3: assertion(s) FAILED"; fi
exit "$fail"
