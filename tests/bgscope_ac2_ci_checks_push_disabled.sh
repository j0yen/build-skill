#!/usr/bin/env bash
# tests/bgscope_ac2_ci_checks_push_disabled.sh — PRD-build-branch-gate-
# scope-artifacts requirement 2 (P0) / AC2: "Given BRANCH_GATE_PUSH=0,
# When the branch gate runs, Then ci-checks is not invoked, the receipt
# reads scope-deferred (push-disabled), and the verdict is not block on
# its account." No origin needed -- BRANCH_GATE_PUSH=0 means the branch
# is never pushed and `autobuilder ci-checks` is never even called.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/bgscope-ac2-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "=== AC2: BRANCH_GATE_PUSH=0 -> ci-checks never invoked, scope-deferred (push-disabled) ==="
bgscope_write_fixture_crate "$T/repo"
git -C "$T/repo" tag v0.1.0
bgscope_write_fakebin "$T/fakebin"
printf 'fixture reviewer prompt\n' > "$T/reviewer-prompt.md"

SLUG="bgscope-ac2-$$"
WT="$(BUILD_TARGET_ROOT="$T/offroot" "$BGSCOPE_WORKTREE_EXTEND" add "$T/repo" "$SLUG" 2>"$T/setup.log")"
expect "setup: worktree created" "[ -d \"$WT\" ]"
echo "docs: harmless change" >> "$WT/README.md"
git -C "$WT" -c user.name="bgscope-test" -c user.email="selftest@example.com" add README.md
git -C "$WT" -c user.name="bgscope-test" -c user.email="selftest@example.com" commit -q -m "docs: harmless change"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"

JOURNAL="$T/journal.md"
OUT="$T/out.log"
BGSCOPE_BRANCH_GATE_PUSH=0 bgscope_run_gate "$T/fakebin" "$T/reviewer-prompt.md" "$WT" "$HEAD_SHA" "$SLUG" "$JOURNAL" "$OUT"
RC=$?
cat "$OUT"

expect "extend-gate.sh exits 0 (ci-checks deferral alone never blocks)" "[ $RC -eq 0 ]"
expect "ci-checks was never invoked (no push, no gh call in the output)" \
  "! grep -q 'workflow(s) on HEAD are not green' \"$OUT\""

WT_TARGET="$(readlink -f "$WT/target" 2>/dev/null || true)"
ci_receipt="$WT_TARGET/autobuilder/receipts/ci-checks.json"
expect "ci-checks.json receipt exists" "[ -f \"$ci_receipt\" ]"
skip_reason="$(jq -r '.skip_reason // empty' "$ci_receipt" 2>/dev/null || true)"
echo "  ci-checks.json skip_reason: $skip_reason"
expect "receipt reads scope-deferred (push-disabled)" "printf '%s' \"$skip_reason\" | grep -q '^push-disabled'"
verdict_field="$(jq -r '.verdict // empty' "$ci_receipt" 2>/dev/null || true)"
expect "receipt's own verdict is pass (never block on its account)" "[ \"$verdict_field\" = pass ]"

line="$(grep '  gate  ' "$JOURNAL" 2>/dev/null | grep -v reviewer-skipped | head -1 || true)"
echo "  journal: $line"
expect "journal line's outcome is pass" "printf '%s' \"$line\" | grep -q '  pass  (scope=branch'"
expect "journal line names deferred=ci-checks" "printf '%s' \"$line\" | grep -q 'deferred=ci-checks'"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac2: ALL PASS"; else echo "bgscope_ac2: assertion(s) FAILED"; fi
exit "$fail"
