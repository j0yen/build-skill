#!/usr/bin/env bash
# boxslots_ac4_disk_term_floors_to_one.sh — PRD-build-burst-run-slots-from-box AC4.
#
# Given a fixture box answering 16 cores / 64 GB / 100 GB and
# BURST_DISK_FLOOR_GB=40, When `run_slot_cap()` is evaluated, Then it
# returns 1 (disk term (100-40)/45 floors to 1) and `status` reports the
# disk term as the binding one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  boxslots AC4: run_slots.cap=1 (disk term (100-40)/45 floors to 1)" \
  "ok  boxslots AC4: run_slots names disk as the binding term"
