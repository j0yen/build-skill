#!/usr/bin/env bash
# unitlive_ac5_arm_exact_declared_set.sh — PRD-buildloop-unit-liveness AC5.
#
# Given the fake systemctl, when loop-arm.sh runs, then its argv log
# shows `enable --now` for exactly the six declared units and nothing
# else, followed by the liveness table; with one unit still inactive it
# exits non-zero (and, once all are active, exits 0).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/unitlive-ac-common.sh"
run_unitlive_suite_and_expect_labels \
  "ok  unitlive_ac5: loop-arm enables exactly the declared six, still-inactive unit -> non-zero exit" \
  "ok  unitlive_ac5b: loop-arm exits 0 once every declared unit is active"
