#!/usr/bin/env bash
# tests/gateinfra_ac1_finalize_verdict_block.sh — PRD-build-gate-finalize-
# verdict-split AC1 (also exercises AC5's legacy/no-baseline shape and
# AC8's finalize_rc/finalize_kind sidecar).
#
# Given a receipt that parses, has decision=block, matches the gate head,
# AND whose intent_card_sha digest matches a real agent/intent-card.json
# in the repo, When `autobuilder reviewer-agent finalize` exits non-zero
# (the reviewer.rs:355-361 shape: every earlier check already passed,
# only the block decision itself made finalize return Err), Then
# extend-gate.sh classifies the exit as a VERDICT (never infra), the
# journal never names finalize-rejected, the receipt file's sha is
# unchanged (extend-gate.sh never rewrites it), and gate-then-land's own
# outcome is `block` (no committed baseline in this repo — every finding
# is new, per gate-delta.sh's legacy no-baseline path) rather than
# `incomplete`/exit 13.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac1.XXXXXX")"
[ -n "${GATEINFRA_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"

# A real agent/intent-card.json this run's receipt digest must match —
# committed so the classifier's re-read of it is deterministic.
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
export FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA="sha256:${card_sha^^}"   # mixed-case + prefix, normalize_card_sha shape
export FAKE_REVIEWER_STDOUT_MODE=json
export FAKE_REVFINALIZE_RC=1
export FAKE_REVFINALIZE_STDERR='reviewer decision is block; risk gate cannot pass until reasons are resolved'
export FAKE_GH_AUTH_RC=0
out="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc=$?
sha_before="$(sha256sum "$receipt" | awk '{print $1}')"
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA \
      FAKE_REVIEWER_STDOUT_MODE FAKE_REVFINALIZE_RC FAKE_REVFINALIZE_STDERR FAKE_GH_AUTH_RC

expect "AC1: exit code is 1 (block — no committed baseline, so every finding is new, never 13/incomplete)" "[ $rc -eq 1 ]"
expect "AC1: no finalize-rejected anywhere in the journal" "! grep -q 'finalize-rejected' '$JOURNAL'"
expect "AC1: journal names the dedicated verdict=block line with finalize_rc" \
  "grep -q 'reviewer-agent verdict=block reasons=\[must-ac-failing-at-head\] finalize_rc=1' '$JOURNAL'"
expect "AC1: journal gate outcome line reads block, never incomplete" \
  "grep -qE '  gate  .*  block  \(' '$JOURNAL' && ! grep -qE '  gate  .*  incomplete  \(' '$JOURNAL'"
sha_after="$(sha256sum "$receipt" | awk '{print $1}')"
expect "AC1: receipt file sha is unchanged (extend-gate.sh never rewrites it)" \
  "[ '$sha_before' = '$sha_after' ]"
expect "AC1: finalize sidecar receipt names finalize_kind=verdict" \
  "[ \"\$(jq -r '.finalize_kind' \"$REPO/target/autobuilder/receipts/reviewer-agent-finalize.json\")\" = verdict ]"
expect "AC1: finalize sidecar receipt names finalize_rc=1" \
  "[ \"\$(jq -r '.finalize_rc' \"$REPO/target/autobuilder/receipts/reviewer-agent-finalize.json\")\" = 1 ]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac1: ALL PASS"
else
  echo "gateinfra_ac1: assertion(s) FAILED"
fi
exit "$fail"
