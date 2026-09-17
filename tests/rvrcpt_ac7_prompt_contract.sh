#!/usr/bin/env bash
# tests/rvrcpt_ac7_prompt_contract.sh — PRD-build-reviewer-receipt-primary
# AC7 (test_prefix rvrcpt): "Given the reviewer prompt file resolved via
# REVIEWER_PROMPT, When it is read, Then it contains the three contract
# lines (receipt file is the deliverable; final message is the receipt
# JSON alone; no background or parallel agents), and the rustbuild commit
# that added them is cited in this PRD's receipts."
#
# Reads the REAL default REVIEWER_PROMPT (extend-gate.sh's own default:
# $HOME/.claude/skills/rustbuild/prompts/reviewer-agent.md — a second,
# already-committed repo this PRD edited directly, per its own Technical
# considerations: "R7 is a second-repo edit made by the builder with the
# rustbuild identity"). RVRCPT_R7_COMMIT (set by reviewer-receipt-
# selftest.sh, which cites it in the verdict-receipt) lets this test also
# confirm that exact commit exists in the rustbuild repo and touched this
# file.
set -uo pipefail

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

PROMPT="${REVIEWER_PROMPT:-$HOME/.claude/skills/rustbuild/prompts/reviewer-agent.md}"

expect "AC7: REVIEWER_PROMPT default resolves to a real file" "[ -f '$PROMPT' ]"

if [ -f "$PROMPT" ]; then
  expect "AC7: prompt states the receipt file is the deliverable" \
    "grep -qi 'your deliverable' '$PROMPT'"
  expect "AC7: prompt states the final message is the receipt JSON alone" \
    "grep -qi 'final message is the receipt JSON alone' '$PROMPT'"
  expect "AC7: prompt forbids background or parallel agents" \
    "grep -qi 'Do not spawn background or parallel agents' '$PROMPT'"
fi

if [ -n "${RVRCPT_R7_COMMIT:-}" ]; then
  # PROMPT is usually a symlink (the rustbuild skill dir under
  # ~/.claude/skills/) — resolve it fully before walking up to the repo
  # root, or `cd ../..` stops inside the symlink's own parent instead of
  # the real rustbuild checkout.
  PROMPT_REAL="$(readlink -f "$PROMPT" 2>/dev/null || echo "$PROMPT")"
  RUSTBUILD_REPO="$(cd "$(dirname "$PROMPT_REAL")/../.." && pwd -P)"
  expect "AC7: cited commit $RVRCPT_R7_COMMIT exists in $RUSTBUILD_REPO" \
    "git -C '$RUSTBUILD_REPO' cat-file -e '$RVRCPT_R7_COMMIT' 2>/dev/null"
  expect "AC7: cited commit touched skill/prompts/reviewer-agent.md" \
    "git -C '$RUSTBUILD_REPO' show --stat '$RVRCPT_R7_COMMIT' 2>/dev/null | grep -q 'skill/prompts/reviewer-agent.md'"
else
  echo "AC7: RVRCPT_R7_COMMIT not set — skipping the commit-citation half (prompt-content checks above still ran)"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "rvrcpt_ac7: ALL PASS"
else
  echo "rvrcpt_ac7: assertion(s) FAILED"
fi
exit "$fail"
