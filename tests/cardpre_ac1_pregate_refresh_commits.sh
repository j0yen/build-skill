#!/usr/bin/env bash
# tests/cardpre_ac1_pregate_refresh_commits.sh — PRD-build-intent-card-
# pregate-refresh AC1: "Given a fixture worktree whose card names PRD-A
# and a claim for PRD-B, When the branch-scope gate starts, Then
# agent/intent-card.json has prd_source = PRD-B's path before the intake
# step and the branch has a commit 'intent-card: refresh from PRD-B'."
#
# "Before the intake step" is proven indirectly: intake ran and passed
# (card-lint validates the SAME card this asserts on), and the refresh
# commit exists — the pre-gate step this PRD adds is the only place in
# extend-gate.sh that touches agent/intent-card.json at all.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/cardpre-common.sh
source "$HERE/fixtures/cardpre-common.sh"

echo "=== AC1: pre-gate refresh names the branch's own PRD and commits it ==="
DIR="$(cardpre_ensure_shared_run mismatch)"
echo "  shared run dir: $DIR"
[ -f "$DIR/RC1" ] || { echo "selftest: shared mismatch run never completed" >&2; exit 2; }

slug="$(cat "$DIR/SLUG")"
wt="$(cat "$DIR/WORKTREE")"
expected_prd="$DIR/prds/build-queue/PRD-$slug.md"

expect "run1 card-after-run1.json exists" "[ -s \"$DIR/card-after-run1.json\" ]"
card_prd_source="$(jq -r '.prd_source // empty' "$DIR/card-after-run1.json" 2>/dev/null)"
echo "  card prd_source after run1: $card_prd_source"
expect "card's prd_source names the branch's own PRD (PRD-B), not PRD-A" \
  "[ \"$card_prd_source\" = \"$expected_prd\" ]"
expect "intake step passed (no 'intake —' block note in run1 output)" \
  "! grep -q 'intake —' \"$DIR/out1.log\""
expect "commit 'intent-card: refresh from PRD-$slug' exists on the branch" \
  "grep -q \"intent-card: refresh from PRD-$slug\" \"$DIR/log-after-run1.txt\""
expect "journal recorded an 'intent-card  refreshed' line for run1" \
  "grep -q 'intent-card  refreshed' \"$DIR/journal.md\""
expect "no intent-card-stale block was recorded (a real PRD was found)" \
  "! grep -q 'intent-card-stale' \"$DIR/out1.log\""

echo "-----"
if [ "$cardpre_fail" -eq 0 ]; then echo "cardpre_ac1: ALL PASS"; else echo "cardpre_ac1: assertion(s) FAILED"; fi
exit "$cardpre_fail"
