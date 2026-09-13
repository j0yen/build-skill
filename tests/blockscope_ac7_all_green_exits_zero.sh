#!/usr/bin/env bash
# blockscope_ac7_all_green_exits_zero.sh — PRD-build-burst-selftest-block-
# scoped-summary AC7.
#
# Given a fixture suite with no failing cases, When it runs, Then every
# block summary passes and the exit status is zero.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/blockscope-ac-common.sh"

blockscope_run '
block_start "A"
expect "A c1: ok" "true"
expect "A c2: ok" "true"
block_start "B"
expect "B c1: ok" "true"
expect_block_green "A" "A: every A case above ran green"
expect_block_green "B" "B: every B case above ran green"
'

fail=0
if [ "$BLOCKSCOPE_RC" -eq 0 ]; then
  echo "ok  AC7: suite exits 0 when nothing failed"
else
  echo "FAIL AC7: expected exit 0, got $BLOCKSCOPE_RC:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
if grep -qF "ok  A: every A case above ran green" <<<"$BLOCKSCOPE_OUT" \
   && grep -qF "ok  B: every B case above ran green" <<<"$BLOCKSCOPE_OUT" \
   && grep -qF "=== PASS ===" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC7: every block summary passes and the total line reads PASS"
else
  echo "FAIL AC7: expected both blocks green and a PASS total line:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
exit $fail
