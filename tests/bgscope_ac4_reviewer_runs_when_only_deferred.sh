#!/usr/bin/env bash
# tests/bgscope_ac4_reviewer_runs_when_only_deferred.sh — PRD-build-
# branch-gate-scope-artifacts requirement 3 (P0) / AC4: "Given a branch
# whose only recorded blocks are scope-deferred, When the gate reaches the
# reviewer step, Then reviewer-agent runs and writes its receipt (no
# reviewer-skipped journal line)." Reuses the shared "correct branch" run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fixtures/bgscope-common.sh
source "$HERE/fixtures/bgscope-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

echo "=== AC4: only-scope-deferred blocks -> reviewer-agent runs, no reviewer-skipped line ==="
DIR="$(bgscope_ensure_shared_run correct)"
echo "  shared run dir: $DIR"
[ -f "$DIR/RC" ] || { echo "selftest: shared correct run never completed" >&2; exit 2; }

target="$(cat "$DIR/TARGET")"
expect "reviewer-agent.json receipt is present" "[ -f \"$target/autobuilder/receipts/reviewer-agent.json\" ]"
expect "no reviewer-skipped journal line was written" "! grep -q 'reviewer-skipped' \"$DIR/journal.md\""
decision="$(jq -r '.decision // empty' "$target/autobuilder/receipts/reviewer-agent.json" 2>/dev/null || true)"
echo "  reviewer decision: $decision"
expect "reviewer decision is pass|concern|block (a real receipt, not empty)" \
  "case \"$decision\" in pass|concern|block) true ;; *) false ;; esac"

echo "-----"
if [ "$fail" -eq 0 ]; then echo "bgscope_ac4: ALL PASS"; else echo "bgscope_ac4: assertion(s) FAILED"; fi
exit "$fail"
