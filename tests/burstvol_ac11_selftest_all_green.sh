#!/usr/bin/env bash
# burstvol_ac11_selftest_all_green.sh —
# PRD-build-burst-persistent-volume AC11.
#
# The burstvol fixture set (AC1-10 above) exits 0 in aggregate.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC11: every burstvol case above ran green"
