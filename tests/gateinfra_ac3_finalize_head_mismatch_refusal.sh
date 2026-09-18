#!/usr/bin/env bash
# tests/gateinfra_ac3_finalize_head_mismatch_refusal.sh — PRD-build-gate-
# finalize-verdict-split AC3.
#
# Given a receipt with decision=block whose head_sha differs from the
# gate head, When finalize exits 1, Then classify_finalize_exit reads
# that as a REFUSAL, not a verdict — same infra:finalize-rejected shape
# AC2/AC12 already lock in, never a block.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac3.XXXXXX")"
[ -n "${GATEINFRA_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"
mkdir -p "$REPO/agent"
printf '{"prd":"build-gate-finalize-verdict-split"}' > "$REPO/agent/intent-card.json"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "add intent-card"
card_sha="$(sha256sum "$REPO/agent/intent-card.json" | awk '{print $1}')"

JOURNAL="$T/journal.md"
: > "$JOURNAL"
receipt="$REPO/target/autobuilder/receipts/reviewer-agent.json"

export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_RECEIPT_REASONS="must-ac-failing-at-head"
export FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA="sha256:${card_sha}"
export FAKE_REVIEWER_RECEIPT_HEAD="0000000000000000000000000000000000dead"   # deliberately wrong
export FAKE_REVIEWER_STDOUT_MODE=json
export FAKE_REVFINALIZE_RC=1
export FAKE_REVFINALIZE_STDERR='reviewer head_sha=0000000000000000000000000000000000dead does not match current HEAD'
export FAKE_GH_AUTH_RC=0
out="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc=$?
sha_before_after="$(sha256sum "$receipt" | awk '{print $1}')"
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA \
      FAKE_REVIEWER_RECEIPT_HEAD FAKE_REVIEWER_STDOUT_MODE FAKE_REVFINALIZE_RC FAKE_REVFINALIZE_STDERR FAKE_GH_AUTH_RC

expect "AC3: exit code is 9 (incomplete/infra — never block)" "[ $rc -eq 9 ]"
expect "AC3: stdout/stderr never claims decision=block" "[[ \"\$out\" != *'decision=block'* ]]"
expect "AC3: no dedicated verdict=block journal line was written" \
  "! grep -q 'reviewer-agent verdict=block' '$JOURNAL'"
expect "AC3: journal infra note reads infra=reviewer-agent:finalize-rejected" \
  "grep -q 'infra=reviewer-agent:finalize-rejected' '$JOURNAL'"
expect "AC3: journal line's outcome is incomplete, never block" \
  "grep -qE '  gate  .*  incomplete  \(' '$JOURNAL' && ! grep -qE '  gate  .*  block  \(' '$JOURNAL'"
expect "AC3: finalize sidecar receipt names finalize_kind=refusal" \
  "[ \"\$(jq -r '.finalize_kind' \"$REPO/target/autobuilder/receipts/reviewer-agent-finalize.json\")\" = refusal ]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac3: ALL PASS"
else
  echo "gateinfra_ac3: assertion(s) FAILED"
fi
exit "$fail"
