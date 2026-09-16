#!/usr/bin/env bash
# seltick_ac4_max_branches_cap.sh —
# PRD-build-select-tick-deterministic AC4: given a fixture with 35
# admissible PRDs and BUILD_MAX_BRANCHES=30, when select-tick.sh runs,
# then exactly 30 are admitted and 5 are skipped with reason "cap".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

for i in $(seq -w 1 35); do
  seltick_write_prd "cap$i" shell "/tmp/seltick-ac4-repo-$i"
done

# BUILD_SUBAGENT_LIMIT=30 (PRD-build-tick-under-dispatch-ledger requirement
# 5 default is 20): this AC is testing BUILD_MAX_BRANCHES's own cap in
# isolation, not the newer subagent-limit clamp — pinned above 30 so it
# never binds here (that clamp gets its own dedicated udl_ac5 test).
out=$(BUILD_MAX_BRANCHES=30 BUILD_SUBAGENT_LIMIT=30 seltick_run --format json)

admitted_n=$(printf '%s' "$out" | "$SELTICK_JQ" '.counts.admitted')
cap_skips=$(printf '%s' "$out" | "$SELTICK_JQ" '[.skipped[] | select(.reason == "cap")] | length')
if [ "$admitted_n" -ne 30 ]; then
  echo "FAIL AC4: expected exactly 30 admitted, got $admitted_n" >&2
  exit 1
fi
if [ "$cap_skips" -ne 5 ]; then
  echo "FAIL AC4: expected exactly 5 cap-skips, got $cap_skips" >&2
  exit 1
fi
echo "ok  AC4: 35 admissible, BUILD_MAX_BRANCHES=30 -> 30 admitted, 5 skipped reason=cap"
