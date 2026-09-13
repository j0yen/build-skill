#!/usr/bin/env bash
# blockscope_ac3_only_final_verdict_uses_fail.sh — PRD-build-burst-selftest-
# block-scoped-summary AC3.
#
# Given the real burst-lane-selftest.sh, When it is inspected, Then the only
# `[ $fail -eq 0 ]` remaining is the final suite verdict line — every block
# summary now calls expect_block_green instead of asserting the raw counter.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/burst-lane-selftest.sh"
[ -f "$SUITE" ] || { echo "FAIL: $SUITE not found" >&2; exit 2; }

fail=0
hits="$(grep -nE 'expect "[^"]*"[[:space:]]+"\[ \$fail -eq 0 \]"' "$SUITE" || true)"
if [ -z "$hits" ]; then
  echo "ok  AC3: no expect call reads \$fail directly; only the final verdict line remains"
else
  echo "FAIL AC3: found expect call(s) still hand-rolling \$fail:"$'\n'"$hits" >&2
  fail=1
fi

verdict="$(grep -cE '^echo "=== \$\(\[ \$fail -eq 0 \]' "$SUITE" || true)"
if [ "$verdict" -eq 1 ]; then
  echo "ok  AC3: the final suite verdict line is still the one legitimate global check"
else
  echo "FAIL AC3: expected exactly one final verdict line referencing \$fail, found $verdict" >&2
  fail=1
fi
exit $fail
