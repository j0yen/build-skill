#!/usr/bin/env bash
# burstvol_ac4_detach_failed_marks_dirty_next_up_fscks.sh —
# PRD-build-burst-persistent-volume AC4.
#
# Given a detach failure at down, when the server still deletes, then the journal records detach-failed, volume_dirty=true is recorded, and the next up runs fsck before mounting.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC4: server still deletes even though detach failed" \
  "ok  burstvol AC4: journal records volume detach-failed" \
  "ok  burstvol AC4: volume state file marks volume_dirty=true" \
  "ok  burstvol AC4: the next up exits 0" \
  "ok  burstvol AC4: the next up ran fsck before mounting (prior detach-failed)"
