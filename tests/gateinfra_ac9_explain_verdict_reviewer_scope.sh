#!/usr/bin/env bash
# tests/gateinfra_ac9_explain_verdict_reviewer_scope.sh — PRD-build-gate-
# finalize-verdict-split AC9.
#
# Given `--explain-verdict`, When run on a gate whose reviewer-agent block
# reached attribution (only possible now that R1/R2's classifier reads a
# finalize verdict exit as block, not infra), Then the reviewer reason
# prints with its scope — no new code: --explain-verdict already reads
# every cached attribution block generically (PRD-build-inherited-blocks-
# delta-pass P1 R5), this proves the reviewer-agent entry actually lands
# in that cache now.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac9.XXXXXX")"
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

export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_RECEIPT_REASONS="must-ac-failing-at-head"
export FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA="sha256:${card_sha}"
export FAKE_REVIEWER_STDOUT_MODE=json
export FAKE_REVFINALIZE_RC=1
export FAKE_REVFINALIZE_STDERR='reviewer decision is block; risk gate cannot pass until reasons are resolved'
export FAKE_GH_AUTH_RC=0
rvrcpt_run_gate "$REPO" "$JOURNAL" >/dev/null 2>&1
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_REVIEWER_RECEIPT_INTENT_CARD_SHA \
      FAKE_REVIEWER_STDOUT_MODE FAKE_REVFINALIZE_RC FAKE_REVFINALIZE_STDERR FAKE_GH_AUTH_RC

explain_out="$(PATH="$RVRCPT_FAKE:$PATH" \
  AUTOBUILDER_CANONICAL_CARGO_TOML="$T/no-such-canonical/Cargo.toml" \
  RUSTBUILD_SCRIPTS="$RVRCPT_FAKE" \
  bash "$RVRCPT_EXTEND_GATE" "$REPO" --explain-verdict 2>&1)"

expect "AC9: --explain-verdict lists a reviewer-agent block line" \
  "[[ \"\$explain_out\" == *'receipt=reviewer-agent'* ]]"
expect "AC9: the reviewer-agent block line carries a scope= field" \
  "[[ \"\$explain_out\" == *'scope='*'receipt=reviewer-agent'* ]]"

echo "--- explain output ---"
printf '%s\n' "$explain_out"
echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac9: ALL PASS"
else
  echo "gateinfra_ac9: assertion(s) FAILED"
fi
exit "$fail"
