#!/usr/bin/env bash
# seltick_ac7_continuation_exempt_from_subcap.sh —
# PRD-build-select-tick-deterministic AC7: given a PRD with
# `Lane: <this host> <ts>` and `Status: building`, when select-tick.sh
# runs, then that slug is first in admitted[] with continuation: true and
# is not counted against the same-target sub-cap for new candidates.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

seltick_write_continuation_prd cont1 contlane /tmp/seltick-ac7-repo
seltick_write_prd newcand shell /tmp/seltick-ac7-repo

# BUILD_SAME_TARGET_CAP=1 (the default): if the continuation counted
# against the tally, newcand (a genuinely NEW candidate on the same
# build_into) would be blocked same-target. It must not be.
out=$(BUILD_SAME_TARGET_CAP=1 seltick_run --lane contlane --format json)

first_slug=$(printf '%s' "$out" | "$SELTICK_JQ" -r '.admitted[0].slug')
if [ "$first_slug" != "cont1" ]; then
  echo "FAIL AC7: expected cont1 admitted first, got: $first_slug" >&2
  exit 1
fi
cont1_flag=$(printf '%s' "$out" | "$SELTICK_JQ" -r '.admitted[] | select(.slug=="cont1") | .continuation')
if [ "$cont1_flag" != "true" ]; then
  echo "FAIL AC7: expected cont1.continuation == true, got $cont1_flag" >&2
  exit 1
fi
printf '%s' "$out" | "$SELTICK_JQ" -e '.admitted[] | select(.slug=="newcand")' >/dev/null \
  || { echo "FAIL AC7: newcand must be admitted -- continuation must not count against sub-cap=1" >&2; exit 1; }
echo "ok  AC7: own-claim continuation admitted first, new candidate on same target not blocked"
