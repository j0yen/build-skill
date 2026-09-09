#!/usr/bin/env bash
# burst-lane_ac7_selection_subcap_formula.sh — PRD-build-burst-lane-ccx53 AC7.
#
# Given a session up on a box reporting 120 GB available and 32 cores, when
# selection runs with ten rust candidates, then 8 are admitted and the
# journal records the AC7-shaped line; given 40 GB available, then 6; given
# no session, then only the local cap of 3 applies and the journal says so.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  sub-cap with no session reports local=3" \
  "ok  sub-cap with no session journals it" \
  "ok  sub-cap admits 8 on a 120GB/32-core box (AC7)" \
  "ok  sub-cap journals the AC7-shaped line" \
  "ok  sub-cap admits 6 on a 40GB/32-core box (AC7)" \
  "ok  sub-cap exits 3 (fallback, never blocks) when the probe fails"
