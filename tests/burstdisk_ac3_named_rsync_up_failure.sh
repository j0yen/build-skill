#!/usr/bin/env bash
# burstdisk_ac3_named_rsync_up_failure.sh — PRD-build-burst-remote-disk-guard AC3.
#
# Given a fake box whose rsync exits 11 with "rsync: write failed: No
# space left on device" on stderr, When `run` is invoked with enough
# reported disk, Then the journal line carries cause=rsync-up-failed
# rc=11 err="...No space left on device" and the captured log exists
# under $STATE_DIR/logs/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstdisk AC3: run exits 3 on a named rsync-up failure" \
  "ok  burstdisk AC3: journal carries rc and the log's last stderr line" \
  "ok  burstdisk AC3: the captured log lives under state/logs, not /tmp"
