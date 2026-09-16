#!/usr/bin/env bash
# tests/cardpre_ac6_postland_check_ok.sh — PRD-build-intent-card-pregate-
# refresh AC6 (P1, R5): "Given gate-then-land.sh post-land with a card
# already refreshed on the branch, When land completes, Then the journal
# has intent-card  check  ok and no refresh commit on main." Runs the
# REAL gate-then-land.sh end to end (same pattern as bgscope_ac7) — the
# branch's own extend-gate.sh --scope branch run (invoked internally by
# gate-then-land.sh) is where R1/R2's pre-gate refresh commits the card
# BEFORE land ever runs, so by the time land completes the card should
# already be correct and R5's post-land step should find nothing to fix.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/cardpre-common.sh
source "$HERE/fixtures/cardpre-common.sh"
GATE_THEN_LAND="$CARDPRE_REPO_ROOT/scripts/gate-then-land.sh"
[ -x "$GATE_THEN_LAND" ] || { echo "selftest: $GATE_THEN_LAND not executable" >&2; exit 2; }

echo "=== AC6: post-land intent-card check is 'ok', no extra commit on main ==="

T="$(mktemp -d "${TMPDIR:-/tmp}/cardpre-ac6.XXXXXX")"
trap 'rm -rf "$T"' EXIT

bgscope_write_fixture_crate "$T/repo"
git -C "$T/repo" tag v0.1.0
bgscope_write_fakebin "$T/fakebin"
printf 'fixture reviewer prompt\n' > "$T/reviewer-prompt.md"
printf 'AC6 fixture land -- no real ship, disposable repo\n' > "$T/tldr.md"

SLUG="cardpre-ac6-$$"
mkdir -p "$T/prds/build-queue"
cardpre_write_prd "$T/prds/build-queue/PRD-$SLUG.md" "$SLUG" postland
jq -n --arg slug "$SLUG" --arg path "$T/prds/build-queue/PRD-$SLUG.md" \
  '{prds: {($slug): {path: $path}}}' > "$T/manifest.json"

WT="$(BUILD_TARGET_ROOT="$T/offroot" "$CARDPRE_WORKTREE_EXTEND" add "$T/repo" "$SLUG" 2>"$T/setup.log")"
echo "docs: harmless change (AC6 land fixture)" >> "$WT/README.md"
git -C "$WT" -c user.name="cardpre-test" -c user.email="selftest@example.com" add README.md
git -C "$WT" -c user.name="cardpre-test" -c user.email="selftest@example.com" commit -q -m "docs: harmless change (AC6 land fixture)"

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
  "BURST_LANE_SH=$CARDPRE_BURST_LANE_FAKE" \
  "EXTEND_GATE_JOURNAL=$JOURNAL" \
  "GATE_THEN_LAND_JOURNAL=$JOURNAL" \
  "INTENT_CARD_REFRESH_MANIFEST=$T/manifest.json" \
  "GATE_PATIENCE_PRD_DIR=$T/prds" \
  timeout -k 5 180 "$GATE_THEN_LAND" "$T/repo" "$SLUG" patch "$T/tldr.md" > "$T/land-out.log" 2>&1
land_rc=$?
cat "$T/land-out.log"
echo "gate-then-land exit code: $land_rc"

expect "gate-then-land.sh exits 0 (landed)" "[ $land_rc -eq 0 ]"
main_sha_after="$(git -C "$T/repo" rev-parse HEAD)"
expect "main's HEAD moved (the branch actually landed)" "[ \"$main_sha_after\" != \"$main_sha_before\" ]"
expect "the branch's own pre-gate refresh committed the card (visible in land's own stderr)" \
  "grep -q 'intent-card  refreshed' \"$JOURNAL\""
expect "post-land check found the card already correct: 'intent-card  check  ok'" \
  "grep -q 'intent-card  check  ok' \"$JOURNAL\""
expect "no intent-card-drift line (nothing to fix post-land)" \
  "! grep -q 'intent-card-drift' \"$JOURNAL\""
card_prd_source="$(jq -r '.prd_source // empty' "$T/repo/agent/intent-card.json" 2>/dev/null)"
expect "landed card's prd_source names this PRD" "[ \"$card_prd_source\" = \"$T/prds/build-queue/PRD-$SLUG.md\" ]"

echo "-----"
if [ "$cardpre_fail" -eq 0 ]; then echo "cardpre_ac6: ALL PASS"; else echo "cardpre_ac6: assertion(s) FAILED"; fi
exit "$cardpre_fail"
