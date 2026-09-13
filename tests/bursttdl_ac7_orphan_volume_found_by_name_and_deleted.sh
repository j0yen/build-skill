#!/usr/bin/env bash
# bursttdl_ac7_orphan_volume_found_by_name_and_deleted.sh —
# PRD-build-burst-teardown-lifecycle AC7.
#
# Given a burst-owned volume present with no session pointer (server
# deleted out-of-band), When `down --force` or `reap --volumes` runs, Then
# the volume is located by name/label and deleted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  bursttdl AC7 setup: the volume is still real in hcloud after the out-of-band server delete" \
  "ok  bursttdl AC7: reap --volumes reports one volume reaped" \
  "ok  bursttdl AC7: the volume is located by name and deleted despite no session pointer" \
  "ok  bursttdl AC7: the deletion is journaled with id and used_pct" \
  "ok  bursttdl AC7: down --force also locates and deletes a stranded volume with no session pointer"
