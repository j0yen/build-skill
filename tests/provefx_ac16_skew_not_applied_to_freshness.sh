#!/usr/bin/env bash
# provefx_ac16_skew_not_applied_to_freshness.sh — PRD-build-burst-prove-
# forensics requirement 11 regression.
#
# Given artifacts whose box-clock mtime lands 82s after the box-clock
# marker's mtime, and a remote_date/skew_s diagnostic reading skew_s=-330
# (the real 2026-09-15T05:08:20Z RedBaron incident, commit 778dd2a: files:
# 5816, marker_mtime=05:02:53Z, newest_mtime=05:04:15Z, remote_date=
# 05:02:50Z, skew_s=-330, yet verdict cause=no-fresh-artifact), When assert
# runs, Then routed=true — the freshness check compares box-clock file
# mtimes to the box-clock marker mtime only; skew_s never shifts either
# side of that comparison, it is diagnostic-only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  provefx AC16: artifacts 82s newer than the marker with skew_s=-330 assert routed=true" \
  "ok  provefx AC16: proof.json routed=true, not no-fresh-artifact"
