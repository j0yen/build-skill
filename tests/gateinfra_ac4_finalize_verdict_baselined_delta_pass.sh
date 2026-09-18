#!/usr/bin/env bash
# tests/gateinfra_ac4_finalize_verdict_baselined_delta_pass.sh —
# PRD-build-gate-finalize-verdict-split AC4.
#
# Given a reviewer block whose every reason is named in
# agent/gate-baseline.json, When verdict assembly runs (gate-delta.sh's
# committed-baseline path — the reviewer block reaches it at all only
# because R1/R2's classifier correctly read this finalize exit as a
# verdict, not infra), Then the gate verdict is delta-pass and
# inherited_blocks names reviewer-agent:<reason>. This is the exact
# 2026-09-18 regression from the PRD's own Grounding (burst-lane-gate-
# debt-2b2982e): the reviewer's sole reason already named in the baseline
# used to hold the branch at exit 13 forever; after this PRD it lands.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac4.XXXXXX")"
[ -n "${GATEINFRA_KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"
mkdir -p "$REPO/agent"
printf '{"prd":"build-gate-finalize-verdict-split"}' > "$REPO/agent/intent-card.json"
# The committed baseline: this run's reviewer block reason is already
# known debt, per gate-delta.sh's schema (autobuilder.gate_baseline.v1).
cat > "$REPO/agent/gate-baseline.json" <<'EOF'
{
  "schema": "autobuilder.gate_baseline.v1",
  "recorded_at": "2026-09-18T03:14:00Z",
  "head_sha": "unknown",
  "receipts": [
    {"name": "reviewer-agent:must-ac-failing-at-head", "reason": "known rollback-plan debt, agent/gate-baseline.json"}
  ]
}
EOF
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m "add intent-card + baseline"
card_sha="$(sha256sum "$REPO/agent/intent-card.json" | awk '{print $1}')"

JOURNAL="$T/journal.md"
: > "$JOURNAL"

export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_RECEIPT_REASONS="must-ac-failing-at-head"
export FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA="sha256:${card_sha}"
export FAKE_REVIEWER_STDOUT_MODE=json
export FAKE_REVFINALIZE_RC=1
export FAKE_REVFINALIZE_STDERR='reviewer decision is block; risk gate cannot pass until reasons are resolved'
export FAKE_GH_AUTH_RC=0
out="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc=$?
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA \
      FAKE_REVIEWER_STDOUT_MODE FAKE_REVFINALIZE_RC FAKE_REVFINALIZE_STDERR FAKE_GH_AUTH_RC

expect "AC4: exits 0 (delta-pass), never 13/incomplete" "[ $rc -eq 0 ]"
expect "AC4: journal verdict is delta-pass" "grep -q 'verdict=delta-pass' '$JOURNAL'"
expect "AC4: journal inherited_blocks names reviewer-agent:must-ac-failing-at-head" \
  "grep -q 'inherited_blocks=\[reviewer-agent:must-ac-failing-at-head\]' '$JOURNAL'"
expect "AC4: journal gate outcome line reads delta-pass" "grep -qE '  gate  .*  delta-pass  \(' '$JOURNAL'"
expect "AC4: no finalize-rejected anywhere in the journal" "! grep -q 'finalize-rejected' '$JOURNAL'"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac4: ALL PASS"
else
  echo "gateinfra_ac4: assertion(s) FAILED"
fi
exit "$fail"
