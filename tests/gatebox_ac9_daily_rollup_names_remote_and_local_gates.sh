#!/usr/bin/env bash
# gatebox_ac9_daily_rollup_names_remote_and_local_gates.sh — PRD-build-gate-on-casper AC9.
#
# Given a day with two remote and one local gate, When the daily rollup
# fires, Then its line contains `gates_remote=2 gates_local=1`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC9: each remote gate attributes slug=gate-<repo> remote=true" \
  "ok  gatebox AC9: the daily rollup line carries gates_remote=2 gates_local=1"
