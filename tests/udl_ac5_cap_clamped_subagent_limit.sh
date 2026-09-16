#!/usr/bin/env bash
# udl_ac5_cap_clamped_subagent_limit.sh —
# PRD-build-tick-under-dispatch-ledger AC5.
#
# Given BUILD_MAX_BRANCHES=30 and 25 eligible fixture PRDs, When
# select-tick runs with BUILD_SUBAGENT_LIMIT=20, Then 20 are admitted, the
# journal has `cap-clamped  (requested=30 effective=20
# cause=subagent-limit)`, and the summary line reads `cap=20`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

for i in $(seq -w 1 25); do
  seltick_write_prd "udl5cap$i" shell "/tmp/udl-ac5-repo-$i"
done

fail=0

out=$(BUILD_MAX_BRANCHES=30 BUILD_SUBAGENT_LIMIT=20 seltick_run --format json)

admitted_n=$(printf '%s' "$out" | "$SELTICK_JQ" '.counts.admitted')
cap_n=$(printf '%s' "$out" | "$SELTICK_JQ" '.counts.cap')
if [ "$admitted_n" -eq 20 ]; then
  echo "ok  AC5: 20 admitted"
else
  echo "FAIL: expected 20 admitted, got $admitted_n"
  fail=1
fi
if [ "$cap_n" -eq 20 ]; then
  echo "ok  AC5: counts.cap == 20"
else
  echo "FAIL: expected counts.cap == 20, got $cap_n"
  fail=1
fi

if grep -qE '  select-tick  cap-clamped  \(requested=30 effective=20 cause=subagent-limit\)' "$JOURNAL"; then
  echo "ok  AC5: journal has cap-clamped requested=30 effective=20"
else
  echo "FAIL: journal missing cap-clamped line; contents:"
  cat "$JOURNAL"
  fail=1
fi

if grep -qE '  select-tick  admitted=20 .* cap=20 ' "$JOURNAL"; then
  echo "ok  AC5: summary line reads cap=20"
else
  echo "FAIL: summary line missing/wrong cap; journal:"
  cat "$JOURNAL"
  fail=1
fi

exit "$fail"
