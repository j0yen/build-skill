#!/usr/bin/env bash
# tests/cardpre_ac2_no_commit_when_current.sh — PRD-build-intent-card-
# pregate-refresh AC2: "Given the card already matches the branch's PRD,
# When the gate starts, Then no commit is made and the journal says
# 'intent-card  current'." Reuses the shared "mismatch" run's SECOND gate
# pass (run2), which starts from run1's already-refreshed card.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/cardpre-common.sh
source "$HERE/fixtures/cardpre-common.sh"

echo "=== AC2: card already current -> no commit, journal says 'intent-card  current' ==="
DIR="$(cardpre_ensure_shared_run mismatch)"
echo "  shared run dir: $DIR"
[ -f "$DIR/RC2" ] || { echo "selftest: shared mismatch run's second pass never completed" >&2; exit 2; }

run1_commits="$(wc -l < "$DIR/log-after-run1.txt")"
run2_commits="$(wc -l < "$DIR/log-after-run2.txt")"
echo "  commits after run1: $run1_commits  after run2: $run2_commits"
expect "run2 added no new commit (commit count unchanged)" "[ \"$run2_commits\" -eq \"$run1_commits\" ]"
expect "journal recorded 'intent-card  current' (run2, card already matched)" \
  "grep -q 'intent-card  current' \"$DIR/journal.md\""

slug="$(cat "$DIR/SLUG")"
expected_prd="$DIR/prds/build-queue/PRD-$slug.md"
card_prd_source="$(jq -r '.prd_source // empty' "$DIR/card-after-run2.json" 2>/dev/null)"
expect "card still names the branch's own PRD after run2" "[ \"$card_prd_source\" = \"$expected_prd\" ]"

echo "-----"
if [ "$cardpre_fail" -eq 0 ]; then echo "cardpre_ac2: ALL PASS"; else echo "cardpre_ac2: assertion(s) FAILED"; fi
exit "$cardpre_fail"
