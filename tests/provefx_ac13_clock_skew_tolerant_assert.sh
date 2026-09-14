#!/usr/bin/env bash
# provefx_ac13_clock_skew_tolerant_assert.sh —
# PRD-build-burst-prove-forensics AC13.
#
# Given a fixture box whose run writes artifacts with mtimes 15 minutes
# BEHIND the local clock (simulating clock skew), When prove runs, Then
# assert passes because the pulled .burst-run-marker is older than those
# artifacts by the box's own clock, and no burst-prove-marker.* file
# remains in $TMPDIR afterwards.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC13: prove routes true when the box's own artifacts land 15m behind wall-clock" \
  "ok  provefx AC13: proof.json routed=true despite the clock skew" \
  "ok  provefx AC13: no burst-prove-marker.* file remains in TMPDIR after prove"
