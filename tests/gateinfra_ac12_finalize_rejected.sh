#!/usr/bin/env bash
# tests/gateinfra_ac12_finalize_rejected.sh — PRD-build-gate-infra-outcome
# AC12 (2026-09-17 amendment, test_prefix gateinfra), regression of the
# 15:54:42Z proof-lane incident: `autobuilder reviewer-agent finalize`
# rejects a reviewer object that DID carry a real decision (a sha-prefix
# mismatch on an otherwise-valid block verdict). Given a stub finalize
# that exits 1 printing "reviewer intent_card_sha=X does not match
# current intent-card sha256=Y", When the phase records the outcome, Then
# the receipt's infra_detail holds that stderr line, the journal infra
# note reads infra=reviewer-agent:finalize-rejected, and the reviewer's
# own decision/block_reasons are copied into the receipt under
# rejected_verdict — a real finding must stay legible even though the
# RUN's own verdict is `infra`, never `block` (R4 unchanged).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac12.XXXXXX")"
[ -n "${GATEINFRA_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_RECEIPT_REASONS="must-ac-failing-at-head"
export FAKE_REVIEWER_STDOUT_MODE=json
export FAKE_REVFINALIZE_RC=1
export FAKE_REVFINALIZE_STDERR='reviewer intent_card_sha=X does not match current intent-card sha256=Y'
export FAKE_GH_AUTH_RC=0
out="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc=$?
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_REVIEWER_STDOUT_MODE \
      FAKE_REVFINALIZE_RC FAKE_REVFINALIZE_STDERR FAKE_GH_AUTH_RC

receipt="$REPO/target/autobuilder/receipts/reviewer-agent.json"
expect "AC12: exit code is 9 (incomplete/infra — never block)" "[ $rc -eq 9 ]"
expect "AC12: stdout/stderr never claims decision=block" "[[ \"\$out\" != *'decision=block'* ]]"
expect "AC12: receipt decision is pass (never block, despite the rejected object saying block)" \
  "[ \"\$(jq -r '.decision' '$receipt')\" = pass ]"
expect "AC12: receipt skip_reason names the finalize-rejected sub-case" \
  "[[ \"\$(jq -r '.skip_reason' '$receipt')\" == infra:reviewer-agent:finalize-rejected:* ]]"
expect "AC12: receipt infra_detail holds the stub finalize's stderr line" \
  "[[ \"\$(jq -r '.infra_detail' '$receipt')\" == *'intent_card_sha=X does not match current intent-card sha256=Y'* ]]"
expect "AC12: receipt rejected_verdict.decision is block (the real finding, preserved)" \
  "[ \"\$(jq -r '.rejected_verdict.decision' '$receipt')\" = block ]"
expect "AC12: receipt rejected_verdict.block_reasons names must-ac-failing-at-head" \
  "[ \"\$(jq -r '.rejected_verdict.block_reasons[0]' '$receipt')\" = must-ac-failing-at-head ]"
expect "AC12: journal infra note reads infra=reviewer-agent:finalize-rejected" \
  "grep -q 'infra=reviewer-agent:finalize-rejected' '$JOURNAL'"
expect "AC12: journal line's outcome is incomplete, never block" \
  "grep -qE '  gate  .*  incomplete  \(' '$JOURNAL' && ! grep -qE '  gate  .*  block  \(' '$JOURNAL'"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac12: ALL PASS"
else
  echo "gateinfra_ac12: assertion(s) FAILED"
fi
exit "$fail"
