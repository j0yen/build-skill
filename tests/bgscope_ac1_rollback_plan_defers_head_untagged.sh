#!/usr/bin/env bash
# tests/bgscope_ac1_rollback_plan_defers_head_untagged.sh — PRD-build-
# branch-gate-scope-artifacts requirement 1 (P0) / AC1: "Given a worktree
# branch with one commit and an untagged HEAD, When extend-gate.sh <wt>
# --head <sha> --scope branch --slug s runs, Then rollback-plan is
# recorded scope-deferred (not blocking) and the journal phases field
# shows rollback-plan:defer." No origin, no CI needed -- BRANCH_GATE_PUSH=0
# keeps this test fast and focused on rollback-plan alone.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/bgscope-ac1-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "=== AC1: a worktree branch with one commit, untagged HEAD ==="
# rollback-plan's real "head-untagged" block_reason is a redeploy-tag-mode
# concept (rollback.rs's revert-commits mode checks revert-cleanliness
# instead, never head tags) -- declare rollback_model: redeploy-tag so
# the REAL autobuilder binary exercises the exact path this AC names, and
# tag the INITIAL commit v0.1.0 so head_tag_status() has an existing tag
# to find "already claimed by a different commit" (the branch's own head,
# unbumped, has no tag of its own -- this is mcphost's real 2026-09-15
# shape: a branch commit that never bumped the crate version).
bgscope_write_fixture_crate "$T/repo" redeploy-tag
git -C "$T/repo" tag v0.1.0
bgscope_write_fakebin "$T/fakebin"
printf 'fixture reviewer prompt\n' > "$T/reviewer-prompt.md"

SLUG="bgscope-ac1-$$"
WT="$(BUILD_TARGET_ROOT="$T/offroot" "$BGSCOPE_WORKTREE_EXTEND" add "$T/repo" "$SLUG" 2>"$T/setup.log")"
expect "setup: worktree created" "[ -d \"$WT\" ]"
echo "docs: one commit ahead of the untagged initial commit" >> "$WT/README.md"
git -C "$WT" -c user.name="bgscope-test" -c user.email="selftest@example.com" add README.md
git -C "$WT" -c user.name="bgscope-test" -c user.email="selftest@example.com" commit -q -m "one commit (AC1 fixture)"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"

JOURNAL="$T/journal.md"
OUT="$T/out.log"
BGSCOPE_BRANCH_GATE_PUSH=0 bgscope_run_gate "$T/fakebin" "$T/reviewer-prompt.md" "$WT" "$HEAD_SHA" "$SLUG" "$JOURNAL" "$OUT"
cat "$OUT"

line="$(grep '  gate  ' "$JOURNAL" 2>/dev/null | grep -v reviewer-skipped | head -1 || true)"
echo "  journal: $line"
expect "journal line carries scope=branch slug=$SLUG" "printf '%s' \"$line\" | grep -q 'scope=branch slug=$SLUG '"
expect "phases field shows rollback-plan:defer" "printf '%s' \"$line\" | grep -q 'rollback-plan:defer'"
expect "rollback-plan is named in deferred=, not in blocking=" \
  "printf '%s' \"$line\" | grep -qE 'deferred=(rollback-plan|[a-z-]+,rollback-plan)'"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac1: ALL PASS"; else echo "bgscope_ac1: assertion(s) FAILED"; fi
exit "$fail"
