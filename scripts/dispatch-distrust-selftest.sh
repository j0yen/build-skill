#!/usr/bin/env bash
# dispatch-distrust-selftest.sh — regression-proofs the coordinator-message
# distrust rule (PRD-build-coordinator-message-distrust, 2026-09-08). This
# is a prompt/doc change, not new code: the enforcement point is the text
# every dispatched branch agent reads, not a script. The smoke test greps
# docs/branch-contract.md's numbered directive and docs/history.md's dated
# citation of it, plus build-contract.md's prose, for the rule's
# distinctive substrings, so a future edit that accidentally drops the
# directive (or the doc section) fails loudly instead of silently.
#
# PRD-build-branch-contract-split moved this rule out of SKILL.md's
# per-branch dispatch bullets (that whole bullet list was deleted —
# superseded by docs/branch-contract.md §9, which every branch dispatch
# now composes from instead of SKILL.md prose) and into
# docs/branch-contract.md (the actionable directive) +
# docs/history.md (the dated PRD citation) — SKILL.md itself carries
# neither any more.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_MD="$HERE/../build-contract.md"
BRANCH_CONTRACT_MD="$HERE/../docs/branch-contract.md"
HISTORY_MD="$HERE/../docs/history.md"

echo "== docs/branch-contract.md carries the distrust-and-reverify directive =="
grep -q "Coordinator-message distrust" "$BRANCH_CONTRACT_MD" \
  || { echo "FAIL: docs/branch-contract.md is missing the coordinator-message-distrust directive"; exit 1; }
grep -q "is NOT actionable on" "$BRANCH_CONTRACT_MD" \
  || { echo "FAIL: docs/branch-contract.md directive is missing the 'not actionable on its own' clause"; exit 1; }
echo ok

echo "== docs/history.md carries the dated PRD-build-coordinator-message-distrust citation =="
grep -q "coordinator-message-distrust — .*PRD-build-coordinator-message-distrust" "$HISTORY_MD" \
  || { echo "FAIL: docs/history.md is missing the coordinator-message-distrust PRD citation"; exit 1; }
echo ok

echo "== build-contract.md documents the same rule in prose =="
grep -q "Branch message trust (PRD-build-coordinator-message-distrust" "$CONTRACT_MD" \
  || { echo "FAIL: build-contract.md is missing the branch message trust section"; exit 1; }
grep -q "re-run the real check before acting on the claim" "$CONTRACT_MD" \
  || { echo "FAIL: build-contract.md is missing the re-verify-before-acting rule"; exit 1; }
echo ok

echo "ALL PASS"
