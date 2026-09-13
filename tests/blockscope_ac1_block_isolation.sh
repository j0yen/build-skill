#!/usr/bin/env bash
# blockscope_ac1_block_isolation.sh — PRD-build-burst-selftest-block-scoped-
# summary AC1.
#
# Given a fixture suite with one deliberately failing case in block A and
# all-passing blocks B and C, When the suite runs, Then block A's summary
# fails and blocks B and C's summaries pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/blockscope-ac-common.sh"

blockscope_run '
block_start "A"
expect "A c1: ok" "true"
expect "A c2: bad" "false"
block_start "B"
expect "B c1: ok" "true"
block_start "C"
expect "C c1: ok" "true"
expect_block_green "A" "A: every A case above ran green"
expect_block_green "B" "B: every B case above ran green"
expect_block_green "C" "C: every C case above ran green"
'

fail=0
if grep -qF "FAIL A: 1 of 2 cases failed" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC1: block A's summary fails and names 1 of 2"
else
  echo "FAIL AC1: block A's summary should have failed naming 1 of 2:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
if grep -qF "ok  B: every B case above ran green" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC1: block B (downstream of A, all-passing) stays green"
else
  echo "FAIL AC1: block B should have stayed green:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
if grep -qF "ok  C: every C case above ran green" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC1: block C (downstream of A, all-passing) stays green"
else
  echo "FAIL AC1: block C should have stayed green:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
exit $fail
