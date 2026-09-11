#!/usr/bin/env bash
# burstvol_ac3_teardown_detach_before_delete.sh —
# PRD-build-burst-persistent-volume AC3.
#
# Given an attached volume, when down runs, then hcloud volume detach happens before server delete, and the journal shows volume detached before down decision=deleted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC3: teardown still deletes cleanly with a volume attached" \
  "ok  burstvol AC3: hcloud volume detach happens before server delete" \
  "ok  burstvol AC3: journal has volume detached before down decision=deleted"
