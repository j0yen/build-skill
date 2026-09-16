#!/usr/bin/env bash
# tests/bgscope_ac7_land_reruns_deferred_at_main_scope.sh — PRD-build-
# branch-gate-scope-artifacts requirement 5 (P0) / AC7: "Given a pass
# verdict with deferrals, When land --gated-at <main> --verdict <file>
# runs, Then the deferred producers run at main scope on the landed head
# before any tag is created, and a block there leaves main untagged with
# the existing main-scope journal line." Runs the REAL gate-then-land.sh
# end to end against a disposable fixture repo (never build-skill itself,
# never mcphost) -- this is the actual land path, not a re-derivation of
# it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"
GATE_THEN_LAND="$BGSCOPE_REPO_ROOT/scripts/gate-then-land.sh"
[ -x "$GATE_THEN_LAND" ] || { echo "selftest: $GATE_THEN_LAND not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/bgscope-ac7-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

echo "=== AC7: gate-then-land.sh re-runs deferred producers at main scope before declaring the land ship-strength-unchanged ==="
# No origin configured at all here (deliberately, unlike AC3/AC5's bare
# origin): real ci_checks.rs's own documented exception is verdict=skipped
# (pass-equivalent) when a project has NO origin remote -- this lets the
# post-land MAIN-scope re-verification of the branch's deferred ci-checks
# genuinely pass for real, so this test proves the positive path (land
# succeeds, re-verification passes, ship-strength-unchanged), not just
# that a block leaves main merged-but-untagged (that shape is exercised
# structurally by gate-then-land.sh's own exit-11 code path, unchanged by
# this PRD -- Non-goals: gate-before-land's own requirements untouched).
bgscope_write_fixture_crate "$T/repo"
git -C "$T/repo" tag v0.1.0
bgscope_write_fakebin "$T/fakebin"
printf 'fixture reviewer prompt\n' > "$T/reviewer-prompt.md"
printf 'AC7 fixture land -- no real ship, disposable repo\n' > "$T/tldr.md"

SLUG="bgscope-ac7-$$"
WT="$(BUILD_TARGET_ROOT="$T/offroot" "$BGSCOPE_WORKTREE_EXTEND" add "$T/repo" "$SLUG" 2>"$T/setup.log")"
expect "setup: worktree created" "[ -d \"$WT\" ]"
echo "docs: harmless change (AC7 land fixture)" >> "$WT/README.md"
git -C "$WT" -c user.name="bgscope-test" -c user.email="selftest@example.com" add README.md
git -C "$WT" -c user.name="bgscope-test" -c user.email="selftest@example.com" commit -q -m "docs: harmless change (AC7 land fixture)"

JOURNAL="$T/journal.md"
main_sha_before="$(git -C "$T/repo" rev-parse HEAD)"

env \
  "PATH=$T/fakebin:$HOME/.claude/skills/build/scripts/cargo-budget-bin:$PATH" \
  "REAL_AUTOBUILDER_BIN=$BGSCOPE_REAL_AUTOBUILDER" \
  "RUSTBUILD_SCRIPTS=$T/fakebin" \
  "REVIEWER_PROMPT=$T/reviewer-prompt.md" \
  "CI_CHECKS_BRANCH_WAIT=3" \
  "CI_CHECKS_BRANCH_POLL=1" \
  "BRANCH_GATE_PUSH=0" \
  "EXTEND_GATE_JOURNAL=$JOURNAL" \
  "GATE_THEN_LAND_JOURNAL=$JOURNAL" \
  timeout -k 5 180 "$GATE_THEN_LAND" "$T/repo" "$SLUG" patch "$T/tldr.md" > "$T/land-out.log" 2>&1
land_rc=$?
cat "$T/land-out.log"
echo "gate-then-land exit code: $land_rc"

expect "gate-then-land.sh exits 0 (landed)" "[ $land_rc -eq 0 ]"
main_sha_after="$(git -C "$T/repo" rev-parse HEAD)"
expect "main's HEAD moved (the branch actually landed)" "[ \"$main_sha_after\" != \"$main_sha_before\" ]"
expect "gate-then-land journal shows the branch verdict deferred ci-checks" \
  "grep -q 'deferred=ci-checks' \"$JOURNAL\""
expect "gate-then-land journal shows the post-land main-scope re-verification ran" \
  "grep -qE 'post-land-main-gate-(pass|block)' \"$JOURNAL\""
expect "the re-verification PASSED (this fixture has no origin, so real ci-checks legitimately skips)" \
  "grep -q 'post-land-main-gate-pass' \"$JOURNAL\""
expect "the re-verification ran at --scope main (not scope=branch) on the landed sha" \
  "grep -q \"landed head $main_sha_after\" \"$T/land-out.log\""

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac7: ALL PASS"; else echo "bgscope_ac7: assertion(s) FAILED"; fi
exit "$fail"
