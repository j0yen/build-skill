#!/usr/bin/env bash
# reality_ac1_plan_lists_substrate_ac_command_and_manual.sh —
# PRD-build-post-ship-reality-check AC1.
#
# Given a fixture PRD whose AC5 says "run `parity ~/wintermute/mcphost`
# against the live lane", When `reality-check.sh plan` runs, Then the plan
# lists AC5 with that command and lists an AC with no derivable command as
# `manual` with a reason.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reality AC1: plan lists AC1 kind=box with the literal parity command" \
  "ok  reality AC1: AC2 (casper, no derivable command) is listed manual with a reason"
