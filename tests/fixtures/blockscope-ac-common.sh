#!/usr/bin/env bash
# blockscope-ac-common.sh — shared harness for tests/blockscope_ac*.sh
# (PRD-build-burst-selftest-block-scoped-summary).
#
# Extracts the real block_of/block_start/block_skip/expect/
# expect_block_green functions straight out of the shipped
# scripts/burst-lane-selftest.sh (never a hand-duplicated copy, which would
# drift and prove nothing an edit to the real functions couldn't silently
# invalidate — same rationale as tests/fixtures/burst-lane-ac-common.sh's
# own header) and runs a fixture body against them in a fresh subprocess,
# so each AC test gets a realistic $fail/exit-code/final-verdict-line
# outcome, not just an in-process function call.
set -uo pipefail
BLOCKSCOPE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCKSCOPE_SUITE="$BLOCKSCOPE_HERE/../../scripts/burst-lane-selftest.sh"
[ -f "$BLOCKSCOPE_SUITE" ] || { echo "FAIL: $BLOCKSCOPE_SUITE not found" >&2; exit 2; }

# The function block runs from `fail=0` (the counters' first definition)
# through the line just before the regression lint's own self-scan — the
# lint needs a real $0/$HERE pointed at the suite file itself and is
# exercised directly by tests/blockscope_ac6_lint_names_the_line.sh, not by
# sourcing it into a fixture body.
BLOCKSCOPE_FUNCS="$(awk '/^fail=0$/{p=1} p{print} /^blockscope_lint_hits=/{exit}' "$BLOCKSCOPE_SUITE" | sed '$d')"

# blockscope_run BODY -> sets BLOCKSCOPE_OUT (combined stdout+stderr) and
# BLOCKSCOPE_RC. BODY is a fixture's own block_start/expect/
# expect_block_green/block_skip calls; the real suite's own closing lines
# (final verdict echo + exit $fail) are appended so a fixture test sees the
# same tail behavior the real suite's callers see.
blockscope_run() {
  local body="$1" script
  script="$(mktemp)"
  {
    printf '%s\n' "$BLOCKSCOPE_FUNCS"
    printf '%s\n' "$body"
    printf '%s\n' 'echo "=== $([ $fail -eq 0 ] && echo PASS || echo FAIL) ==="'
    printf '%s\n' 'exit $fail'
  } > "$script"
  BLOCKSCOPE_OUT="$(bash "$script" 2>&1)"
  BLOCKSCOPE_RC=$?
  rm -f "$script"
}
