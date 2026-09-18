#!/usr/bin/env bash
# contractsplit_ac1_branch_contract_size_and_dates.sh —
# PRD-build-branch-contract-split AC1: given the split landed, when
# `wc -l docs/branch-contract.md` runs, then it is <= 400 and
# `grep -cE '20[0-9]{2}-[0-9]{2}-[0-9]{2}'` on it is 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
FILE="$REPO_ROOT/docs/branch-contract.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then
    echo "ok  $label"
  else
    echo "FAIL $label" >&2
    fail=1
  fi
}

expect "AC1: docs/branch-contract.md exists" "[ -f '$FILE' ]"
lines="$(wc -l < "$FILE" 2>/dev/null || echo 999999)"
expect "AC1: wc -l docs/branch-contract.md <= 400 (got $lines)" "[ '$lines' -le 400 ]"
# grep -c always prints a count (0 or more) on stdout regardless of
# whether it found a match — its EXIT code is what's 1 on zero matches,
# so `grep -c ... || echo 0` would wrongly append a second "0" line here.
dates="$(grep -cE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$FILE" 2>/dev/null)"
dates="${dates:-0}"
expect "AC1: grep -cE date-pattern docs/branch-contract.md == 0 (got $dates)" "[ '$dates' -eq 0 ]"

exit "$fail"
