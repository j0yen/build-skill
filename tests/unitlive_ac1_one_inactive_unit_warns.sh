#!/usr/bin/env bash
# unitlive_ac1_one_inactive_unit_warns.sh — PRD-buildloop-unit-liveness AC1.
#
# Given loop-units.txt with six units for the test host and a fake
# systemctl reporting one of them inactive, when loop-liveness.sh runs,
# then it prints one line per unit, a `LIVENESS WARN unit=<u>
# inactive_since=<ISO>` line, and exits 1.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/unitlive-ac-common.sh"
run_unitlive_suite_and_expect_labels \
  "ok  unitlive_ac1: one inactive unit -> per-unit lines + one WARN line, exit 1"
