#!/usr/bin/env bash
# volid_ac6_name_based_reap_deletes_orphan.sh — PRD-build-burst-volume-id-
# parse AC6.
#
# Given an unattached wm-burst-build volume with no live session, when
# `reap --volumes` runs, then it is deleted and journaled with id, size,
# and age — found by name alone, with no volume.json to consult.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  volidfix AC6: reap --volumes reports one volume reaped" \
  "ok  volidfix AC6: the deletion is journaled with id, size, and a non-zero age"
