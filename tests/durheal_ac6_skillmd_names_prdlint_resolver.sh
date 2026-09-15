#!/usr/bin/env bash
# durheal_ac6_skillmd_names_prdlint_resolver.sh — PRD-build-classification-
# durable-heal AC6.
#
# Given SKILL.md after this PRD, When grepped, Then the Depends-on gate
# names prd-lint.sh as the resolver and no longer instructs the agent to
# resolve names itself.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HERE/../SKILL.md"
[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Grab the Depends-on gate paragraph (from its heading to the next blank
# line) so this test is scoped to that section, not the whole file.
para="$(awk '/^\*\*Depends-on gate/{flag=1} flag{print} flag && /^$/{exit}' "$SKILL")"

expect "Depends-on gate paragraph names prd-lint.sh as the resolver" \
  "grep -q 'prd-lint.sh' <<<\"\$para\""
expect "Depends-on gate paragraph no longer says to resolve the name by hand" \
  "! grep -qi 'resolve the name against' <<<\"\$para\""
expect "Depends-on gate paragraph names depends-on-missing as the typo verdict" \
  "grep -q 'depends-on-missing' <<<\"\$para\""

exit $fail
