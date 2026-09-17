#!/usr/bin/env bash
# tests/gateinfra_ac7_relabel_sed_removed.sh — PRD-build-gate-infra-outcome
# AC7 (test_prefix gateinfra): the `_reviewer_verdict = infra` relabel sed
# (`s/✗ reviewer-agent —/✗ reviewer-agent:infra —/`) that used to sit right
# after the real block-reason relabel is gone — dead the moment R1 made an
# infra reviewer run write a `decision: "pass"` receipt (the aggregator
# never emits a "✗ reviewer-agent —" line for it to rewrite in the first
# place). The real block-reason relabel (PRD-build-reviewer-receipt-
# primary R6) must still be present — this only asserts the infra one is
# gone, not that reviewer-agent relabeling in general disappeared.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
EXTEND_GATE="$SKILL_DIR/scripts/extend-gate.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

expect "AC7: the infra relabel sed command is gone from extend-gate.sh" \
  "! grep -q \"sed 's/✗ reviewer-agent —/✗ reviewer-agent:infra —/'\" '$EXTEND_GATE'"
expect "AC7: no \$_reviewer_verdict = infra branch remains in the relabel block" \
  "! grep -q 'elif \[ \"\$_reviewer_verdict\" = infra \]' '$EXTEND_GATE'"
expect "AC7: the real block-reason relabel (PRD-build-reviewer-receipt-primary R6) is still present" \
  "grep -q '_reviewer_first_reason' '$EXTEND_GATE'"
expect "AC7: run_reviewer's own infra) call site still exists (R1's receipt-writing branch)" \
  "grep -q 'note_infra \"\${_reviewer_infra_phase}' '$EXTEND_GATE'"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac7: ALL PASS"
else
  echo "gateinfra_ac7: assertion(s) FAILED"
fi
exit "$fail"
