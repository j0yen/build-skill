#!/usr/bin/env bash
# burst-lane_ac13_cost_ledger_hours_eur_prds.sh — PRD-build-burst-lane-ccx53 AC13.
#
# Given a session torn down, when burst-lane.sh cost --today runs, then it
# prints hours and euros for that session and the PRD slugs it served.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  cost ledger got a row" \
  "ok  cost ledger row records the PRDs this session served (req 13)" \
  "ok  cost --today prints hours and euros" \
  "ok  cost --today prints the PRDs served this session (AC13)"
