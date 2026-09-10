#!/usr/bin/env bash
# burstpar_ac5_killed_holder_releases_lock.sh — PRD-build-burst-parallel-runs AC5.
#
# Given a run holder killed mid-run, when it dies, then its slot and
# worktree lock release (flock semantics) and a waiting run proceeds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstpar-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5: killed holder releases slot+worktree lock; waiting run proceeds"
