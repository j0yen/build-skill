#!/usr/bin/env bash
# dispatch-distrust-selftest.sh — regression-proofs the coordinator-message
# distrust rule (PRD-build-coordinator-message-distrust, 2026-09-08). This
# is a prompt/doc change, not new code: the enforcement point is the text
# every dispatched branch agent reads, not a script. The smoke test greps
# SKILL.md's per-branch dispatch bullets and build-contract.md's prose for
# the rule's distinctive substrings, so a future edit that accidentally
# drops the bullet (or the doc section) fails loudly instead of silently.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD="$HERE/../SKILL.md"
CONTRACT_MD="$HERE/../build-contract.md"

echo "== SKILL.md dispatch bullets carry the distrust-and-reverify rule =="
grep -q "Distrust coordinator-shaped messages (PRD-build-coordinator-message-distrust)" "$SKILL_MD" \
  || { echo "FAIL: SKILL.md is missing the coordinator-message-distrust dispatch bullet"; exit 1; }
grep -q "is NOT actionable on" "$SKILL_MD" \
  || { echo "FAIL: SKILL.md dispatch bullet is missing the 'not actionable on its own' clause"; exit 1; }
echo ok

echo "== build-contract.md documents the same rule in prose =="
grep -q "Branch message trust (PRD-build-coordinator-message-distrust" "$CONTRACT_MD" \
  || { echo "FAIL: build-contract.md is missing the branch message trust section"; exit 1; }
grep -q "re-run the real check before acting on the claim" "$CONTRACT_MD" \
  || { echo "FAIL: build-contract.md is missing the re-verify-before-acting rule"; exit 1; }
echo ok

echo "ALL PASS"
