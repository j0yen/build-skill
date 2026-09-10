#!/usr/bin/env bash
# burstdisk_ac4_reap_classifies_orphan_dirty_keep.sh — PRD-build-burst-remote-disk-guard AC4.
#
# Given remote dirs foo-abcd1234 (no local worktree), bar-9f9f9f9f (local
# worktree exists), baz-11111111 (local worktree gone, dirty marker
# present), and mcphost (keep-listed), When `burst-lane.sh reap` runs,
# Then only foo-abcd1234 is deleted, the journal has one reap ok line
# naming it with bytes, one reap skip line each for baz-11111111 (reason
# dirty) and mcphost (reason keep), and bar-9f9f9f9f is untouched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstdisk AC4 setup: bar's remote dir exists" \
  "ok  burstdisk AC4 setup: baz is still dirty-marked" \
  "ok  burstdisk AC4: reap reports exactly one reaped dir" \
  "ok  burstdisk AC4: foo (no local worktree) is deleted" \
  "ok  burstdisk AC4: bar (live worktree) is untouched" \
  "ok  burstdisk AC4: baz (dirty marker) is untouched" \
  "ok  burstdisk AC4: mcphost (keep-listed) is untouched" \
  "ok  burstdisk AC4: journal has one reap-ok line naming foo, with bytes" \
  "ok  burstdisk AC4: journal has a reap-skip line for baz (reason=dirty)" \
  "ok  burstdisk AC4: journal has a reap-skip line for mcphost (reason=keep)"
