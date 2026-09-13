#!/usr/bin/env bash
# blockscope_ac4_names_n_of_m.sh — PRD-build-burst-selftest-block-scoped-
# summary AC4.
#
# Given a block with 3 failing cases out of 44, When its summary fails, Then
# the message names 3 and 44 — the PRD's own worked example
# ("bursthyg: 3 of 44 cases failed").
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/blockscope-ac-common.sh"

body='block_start "bursthyg"
for i in $(seq 1 44); do
  if [ "$i" -le 3 ]; then
    expect "bursthyg c$i: bad" "false" >/dev/null 2>&1
  else
    expect "bursthyg c$i: ok" "true" >/dev/null
  fi
done
expect_block_green "bursthyg" "bursthyg: every bursthyg case above ran green"'
blockscope_run "$body"

fail=0
if grep -qF "FAIL bursthyg: 3 of 44 cases failed" <<<"$BLOCKSCOPE_OUT"; then
  echo "ok  AC4: the failing summary names 3 and 44"
else
  echo "FAIL AC4: expected 'FAIL bursthyg: 3 of 44 cases failed', got:"$'\n'"$BLOCKSCOPE_OUT" >&2
  fail=1
fi
exit $fail
