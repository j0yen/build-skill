#!/usr/bin/env bash
# boxslots_ac9_selftest_reports_new_cases_by_name.sh — PRD-build-burst-run-slots-from-box AC9.
#
# Given the whole burst-lane-selftest suite, When it runs, Then it exits 0
# and reports the new `boxslots` cases by name — one representative label
# per AC1-AC7 (the full set is exercised by the other
# tests/boxslots_ac<N>_*.sh wrappers; this one asserts the suite as a
# whole reports every AC number, not just any one of them). AC9's own
# second half (burstpar-selftest.sh also green) is proven by this repo's
# CI/gate running both selftests in the same pass, not duplicated here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  boxslots AC1: journal names cap=8 source=box bound=cpu" \
  "ok  boxslots AC2: all 12 runs complete (12 'run routed' journal lines)" \
  "ok  boxslots AC3: run_slots.source=env" \
  "ok  boxslots AC4: run_slots names disk as the binding term" \
  "ok  boxslots AC5: run_slots.cap=4 source=default when the box probe failed" \
  "ok  boxslots AC6: cmd_sub_cap's own body has no inline nproc/N or avail_gb/N arithmetic" \
  "ok  boxslots AC7: journal names the deprecated knob and its replacement"
