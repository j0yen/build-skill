#!/usr/bin/env bash
# seltick_ac1_burst_subcap_widens_admission.sh —
# PRD-build-select-tick-deterministic AC1: given a fixture PRD dir with 8
# queued rust-extend PRDs on one build_into and a fake burst session
# reporting sub-cap=8, BUILD_DISTINCT_TARGETS=0, BUILD_MAX_BRANCHES=30,
# when select-tick.sh --format json runs, then counts.admitted is 8 and
# admitted[] lists all 8 slugs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/seltick-common.sh"
seltick_setup

for i in 1 2 3 4 5 6 7 8; do
  seltick_write_prd "rext$i" rust-extend /tmp/seltick-ac1-shared-repo
done

FAKE_BURST_READY=true
FAKE_BURST_WIDTH=8
# select-guard.sh's burst cap is min(BUILD_SAME_TARGET_CAP_BURST (default
# 4), width) -- BUILD_SAME_TARGET_CAP_BURST=8 so width=8 actually reaches
# sub-cap=8 (the default 4 would cap it there instead).
out=$(BUILD_DISTINCT_TARGETS=0 BUILD_MAX_BRANCHES=30 BUILD_SAME_TARGET_CAP_BURST=8 seltick_run --format json)

admitted_n=$(printf '%s' "$out" | "$SELTICK_JQ" '.counts.admitted')
if [ "$admitted_n" -ne 8 ]; then
  echo "FAIL AC1: expected counts.admitted == 8, got $admitted_n: $out" >&2
  exit 1
fi
for i in 1 2 3 4 5 6 7 8; do
  printf '%s' "$out" | "$SELTICK_JQ" -e --arg s "rext$i" '.admitted[] | select(.slug == $s)' >/dev/null \
    || { echo "FAIL AC1: rext$i missing from admitted[]" >&2; exit 1; }
done
echo "ok  AC1: 8 of 8 rust-extend PRDs on one build_into admitted under burst sub-cap=8"
