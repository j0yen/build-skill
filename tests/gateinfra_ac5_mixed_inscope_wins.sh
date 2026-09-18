#!/usr/bin/env bash
# tests/gateinfra_ac5_mixed_inscope_wins.sh — PRD-build-gate-finalize-
# verdict-split AC5.
#
# Given a reviewer block with one in-scope reason and one inherited
# (baselined) reason, When verdict assembly runs, Then the verdict is
# block and the journal names the in-scope reason — never a false
# delta-pass. gate-delta.sh's baseline match is a plain name lookup on
# the ONE "reviewer-agent:<reason>" line extend-gate.sh relabels
# `autobuilder gate`'s output with, so which reason becomes that line's
# name decides the outcome: always picking the first CSV reason (the bug
# this test guards, reproduced 2026-09-18) silently hid the in-scope
# reason whenever it happened to sort after the baselined one, yielding a
# false delta-pass with the in-scope finding invisible to attribution.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac5.XXXXXX")"
[ -n "${GATEINFRA_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"
mkdir -p "$REPO/agent"
printf '{"prd":"build-gate-finalize-verdict-split"}' > "$REPO/agent/intent-card.json"
# Only "must-ac-failing-at-head" is known debt; "brand-new-in-scope-defect"
# is not — the reviewer block below names both, in that order (baselined
# reason FIRST), so a naive first-reason pick would misfile this as
# fully inherited.
cat > "$REPO/agent/gate-baseline.json" <<'EOF'
{
  "schema": "autobuilder.gate_baseline.v1",
  "recorded_at": "2026-09-18T03:14:00Z",
  "head_sha": "unknown",
  "receipts": [
    {"name": "reviewer-agent:must-ac-failing-at-head", "reason": "known baselined debt"}
  ]
}
EOF
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "add intent-card + baseline"
card_sha="$(sha256sum "$REPO/agent/intent-card.json" | awk '{print $1}')"

JOURNAL="$T/journal.md"
: > "$JOURNAL"

export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_RECEIPT_REASONS="must-ac-failing-at-head,brand-new-in-scope-defect"
export FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA="sha256:${card_sha}"
export FAKE_REVIEWER_STDOUT_MODE=json
export FAKE_REVFINALIZE_RC=1
export FAKE_REVFINALIZE_STDERR='reviewer decision is block; risk gate cannot pass until reasons are resolved'
export FAKE_GH_AUTH_RC=0
out="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc=$?
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA \
      FAKE_REVIEWER_STDOUT_MODE FAKE_REVFINALIZE_RC FAKE_REVFINALIZE_STDERR FAKE_GH_AUTH_RC

expect "AC5: exits 1 (block — an in-scope reason exists, never a false delta-pass)" "[ $rc -eq 1 ]"
expect "AC5: never delta-pass in the journal" "! grep -q 'verdict=delta-pass' '$JOURNAL'"
expect "AC5: journal gate outcome line reads block" "grep -qE '  gate  .*  block  \(' '$JOURNAL'"
expect "AC5: extend-gate names the in-scope reason as new_blocks (never buried behind the baselined reason)" \
  "grep -q 'new_blocks=reviewer-agent:brand-new-in-scope-defect' <<<\"\$out\""
expect "AC5: the relabeled autobuilder-gate line names the in-scope reason, not the baselined one" \
  "grep -q '✗ reviewer-agent:brand-new-in-scope-defect —' <<<\"\$out\""
expect "AC5: journal's reviewer-agent verdict line still lists both reasons" \
  "grep -q 'reviewer-agent verdict=block reasons=\[must-ac-failing-at-head,brand-new-in-scope-defect\]' '$JOURNAL'"
expect "AC5: no finalize-rejected anywhere in the journal" "! grep -q 'finalize-rejected' '$JOURNAL'"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac5: ALL PASS"
else
  echo "gateinfra_ac5: assertion(s) FAILED"
fi
exit "$fail"
