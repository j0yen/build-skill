#!/usr/bin/env bash
# boxslots_ac5_failed_probe_falls_back_default.sh — PRD-build-burst-run-slots-from-box AC5.
#
# Given a session whose box probe failed, When `run_slot_cap()` is
# evaluated, Then it returns 4 with `source=default` and the journal has
# `up  box-probe  failed`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  boxslots AC5: journal names the failed box probe" \
  "ok  boxslots AC5: run_slots.cap=4 source=default when the box probe failed"
