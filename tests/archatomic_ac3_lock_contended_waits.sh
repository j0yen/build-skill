#!/usr/bin/env bash
# archatomic_ac3_lock_contended_waits.sh —
# PRD-build-archive-atomic-commit AC3: given the fixture with the
# integrate lock held by another process for 5s, when archive-commit.sh
# runs, then it waits, proceeds after release, and the journal line
# shows lock_wait of at least 4.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archatomic-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: exits 0 after the holder releases" \
  "ok  AC3: lock_wait is at least 4" \
  "ok  AC3: the archive still landed"
