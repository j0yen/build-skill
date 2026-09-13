#!/usr/bin/env bash
# blockscope_ac2_suite_exit_unchanged.sh — PRD-build-burst-selftest-block-
# scoped-summary AC2.
#
# Given the same AC1 run (one failing case in block A, B/C all-passing),
# When the suite exits, Then its exit status is non-zero and the total line
# reports the suite-wide failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/blockscope-ac-common.sh"

blockscope_run '
block_start "A"
expect "A c1: ok" "true"
expect "A c2: bad" "false"
block_start "B"
expect "B c1: ok" "true"
expect_block_green "A" "A: every A case above ran green"
expect_block_green "B" "B: every B case above ran green"
'

fail=0
if [ "$BLOCKSCOPE_RC" -ne 0 ]; then
  echo "ok  AC2: suite exits non-zero when any case failed (rc=$BLOCKSCOPE_RC)"
else
  echo "FAIL AC2: suite exited 0 despite a failing case" >&2
  fail=1
fi
if grep -qF "=== FAIL ===" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC2: the total line reports the suite-wide failure"
else
  echo "FAIL AC2: expected the final === FAIL === line:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
exit $fail
