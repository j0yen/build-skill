#!/usr/bin/env bash
# burstvol_ac10_moved_root_marker_is_cold_not_failed.sh —
# PRD-build-burst-persistent-volume AC10.
#
# Given a dirty marker whose remote_path predates a moved REMOTE_ROOT, when pull runs, then it is treated as cold (not rsync-failed), journaled with cause=remote-path-missing, and the stale marker is cleared.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC10: pull against a marker under a moved root exits 0 (cold, not an error)" \
  "ok  burstvol AC10: journal records pull cold cause=remote-path-missing" \
  "ok  burstvol AC10: never journaled as rsync-failed for this worktree" \
  "ok  burstvol AC10: the stale marker was cleared"
