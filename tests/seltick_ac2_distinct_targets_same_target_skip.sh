#!/usr/bin/env bash
# seltick_ac2_distinct_targets_same_target_skip.sh —
# PRD-build-select-tick-deterministic AC2: given AC1's fixture with
# BUILD_DISTINCT_TARGETS=1, when select-tick.sh runs, then counts.admitted
# is 1 and the other 7 appear in skipped[] with reason "same-target".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

for i in 1 2 3 4 5 6 7 8; do
  seltick_write_prd "rext$i" rust-extend /tmp/seltick-ac2-shared-repo
done

# BUILD_DISTINCT_TARGETS=1 forces the compat cap of 1 regardless of burst
# width (same as select-guard.sh's own compat-knob behavior), so no fake
# burst tuning is needed here.
out=$(BUILD_DISTINCT_TARGETS=1 BUILD_MAX_BRANCHES=30 seltick_run --format json)

admitted_n=$(printf '%s' "$out" | "$SELTICK_JQ" '.counts.admitted')
if [ "$admitted_n" -ne 1 ]; then
  echo "FAIL AC2: expected counts.admitted == 1, got $admitted_n: $out" >&2
  exit 1
fi
same_target_n=$(printf '%s' "$out" | "$SELTICK_JQ" '[.skipped[] | select(.reason == "same-target")] | length')
if [ "$same_target_n" -ne 7 ]; then
  echo "FAIL AC2: expected 7 same-target skips, got $same_target_n: $out" >&2
  exit 1
fi
echo "ok  AC2: BUILD_DISTINCT_TARGETS=1 admits 1, skips the other 7 reason=same-target"
