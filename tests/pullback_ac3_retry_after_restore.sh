#!/usr/bin/env bash
# pullback_ac3_retry_after_restore.sh — PRD-build-burst-pull-back-restore
# AC3.
#
# Given that same worktree after the floor is restored, When `pull` runs
# again, Then `target/` is present locally, the marker is cleared, and
# `pulled` is printed.
#
# GAP: no fixture in scripts/burst-lane-selftest.sh does this. The
# "burstvol AC9" block (~line 3260) defers WT_BV9 once via
# BURST_LANE_LOCAL_FREE_GB=20, but never unsets/restores that override and
# re-pulls the SAME worktree afterward — it moves straight on to "burstvol
# AC10" and "burstpull AC3b", both against freshly created worktrees, not
# a retry of WT_BV9. There is no case anywhere else in the suite that
# re-pulls a previously-deferred worktree after the guard's inputs change.
# This is a real, unimplemented coverage gap for AC3, not a tmpfs or
# environment artifact — reported as a hard failure rather than a
# tautological exit 0.
set -uo pipefail
echo "FAIL pullback AC3: GAP — no selftest fixture re-pulls a deferred worktree after BURST_LOCAL_DISK_FLOOR_GB/BURST_LANE_LOCAL_FREE_GB is restored. scripts/burst-lane-selftest.sh's burstvol AC9 block (~line 3260-3286) defers WT_BV9 once and moves on; AC10/AC3b that follow use fresh worktrees instead of retrying WT_BV9. Until such a fixture exists, AC3 has no case to pair with — write one (defer, unset the override / raise the simulated free space, pull WT_BV9 again, assert target/ present + marker cleared + stdout=pulled) before this wrapper can report anything but a gap." >&2
exit 1
