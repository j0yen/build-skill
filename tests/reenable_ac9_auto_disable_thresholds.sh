#!/usr/bin/env bash
# reenable_ac9_auto_disable_thresholds.sh — PRD-build-burst-dispatch-reenable AC9.
#
# Given two sessions inside 24h that ended with runs_served=0 or a
# fallback cause, When the second ends, Then the drop-in is removed,
# burst_configured() is false, and the journal and stderr carry
# `auto-disabled (cause=zero-run-sessions sessions=...)`; given instead
# a day whose deleted-box cost reaches BURST_AUTO_DISABLE_EUR_PER_DAY
# with no routed run, When that session ends, Then the same removal
# happens with cause=eur-ceiling.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC9a: one zero-run session alone does not auto-disable" \
  "ok  reenable AC9a: nothing printed to stderr" \
  "ok  reenable AC9a: no auto-disabled line journaled" \
  "ok  reenable AC9b: the drop-in is removed" \
  "ok  reenable AC9b: journal carries auto-disabled (cause=zero-run-sessions sessions=s1,s2)" \
  "ok  reenable AC9b: the same line was printed to stderr" \
  "ok  reenable AC9c: a served session in the pair blocks zero-run-sessions" \
  "ok  reenable AC9d: the drop-in is removed" \
  "ok  reenable AC9d: journal carries auto-disabled (cause=eur-ceiling eur=2.5000)" \
  "ok  reenable AC9d: the same line was printed to stderr" \
  "ok  reenable AC9e: under the eur ceiling does not auto-disable" \
  "ok  reenable AC9f: no drop-in to remove -> no journal line, no stderr"
