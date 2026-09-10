#!/usr/bin/env bash
# burstdisk_ac5_reap_ssh_failure_never_blocks_down.sh — PRD-build-burst-remote-disk-guard AC5.
#
# Given a session is up and the fake ssh returns rc 255 during reap, When
# `burst-lane.sh down` runs, Then the journal has `reap  fail  (cause=ssh
# rc=255)` followed by the normal `down  decision=…` line and `down`
# exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstdisk AC5: down still exits 0 despite a failed reap listing" \
  "ok  burstdisk AC5: journal names the ssh rc" \
  "ok  burstdisk AC5: the reap-fail line precedes down's own decision line"
