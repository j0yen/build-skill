#!/usr/bin/env bash
# lintdr_ac5_docs_name_both_keys.sh —
# PRD-build-prd-lint-deferred-reasons-key AC5.
#
# Given the shipped build-contract.md and SKILL.md, When grepped, Then
# build-contract.md has a `deferred_ac_reasons` key-table row and SKILL.md's
# C5 (the Verified-completed checklist, check #5) names both
# `mock_justifications` and `deferred_ac_reasons`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONTRACT="$HERE/../build-contract.md"
SKILL="$HERE/../SKILL.md"
[ -f "$CONTRACT" ] || { echo "FAIL: $CONTRACT not found" >&2; exit 2; }
[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

expect "build-contract.md has a deferred_ac_reasons key-table row" \
  "grep -qE '^\\| \`deferred_ac_reasons\`' '$CONTRACT'"

# Scope to check #5's own paragraph (from its numbered "5." line to the
# "Check #5 is DERIVED" section that follows it), same span-extraction
# convention as durheal_ac6.
c5="$(awk '/^  5\. Every acceptance test the PRD declared/{flag=1} flag{print} /Check #5 is DERIVED/{exit}' "$SKILL")"
expect "SKILL.md C5 paragraph names mock_justifications" \
  "grep -q 'mock_justifications' <<<\"\$c5\""
expect "SKILL.md C5 paragraph names deferred_ac_reasons" \
  "grep -q 'deferred_ac_reasons' <<<\"\$c5\""

exit $fail
