#!/usr/bin/env bash
# blockscope_ac5_skip_no_neighbor_baseline.sh — PRD-build-burst-selftest-
# block-scoped-summary AC5.
#
# Given a block skipped because burst is dormant, When the suite runs, Then
# that block reports skipped, its summary is neither green nor red, and the
# next block's baseline is its own (a skip never lends its zero-count to a
# neighbor, and a neighbor's real failure never bleeds into the skip line).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/blockscope-ac-common.sh"

blockscope_run '
block_start "A"
expect "A c1: bad" "false"
block_skip "D"
block_start "E"
expect "E c1: ok" "true"
expect_block_green "A" "A: every A case above ran green"
expect_block_green "D" "D: every D case above ran green"
expect_block_green "E" "E: every E case above ran green"
'

fail=0
if grep -qF "FAIL A: 1 of 1 cases failed" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC5: block A's own failure is reported normally"
else
  echo "FAIL AC5: block A should report its own failure:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
if grep -qF "SKIP D: block skipped, no cases ran" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC5: the skipped block reports skipped, neither green nor red"
else
  echo "FAIL AC5: expected a SKIP line for D:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
if grep -qF "ok  D: every D case above ran green" <<<"$BLOCKSCOPE_OUT" || grep -qF "FAIL D:" <<<"$BLOCKSCOPE_OUT"; then
  echo "FAIL AC5: the skipped block must not print an ok/FAIL summary line" >&2
  fail=1
else
  echo "ok  AC5: the skipped block never prints an ok/FAIL summary"
fi
if grep -qF "ok  E: every E case above ran green" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC5: the next block (E) took its own baseline, not the skip's or A's"
else
  echo "FAIL AC5: block E should be green on its own merits:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
exit $fail
