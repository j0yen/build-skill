#!/usr/bin/env bash
# shwt_ac2_land_rebased_journal.sh — PRD-build-shell-worktree-isolation AC2.
#
# Given two worktrees s1 and s2 off the same main where s1 lands first with
# a commit touching README.md and s2 has a commit touching scripts/x.sh,
# When `land <repo> s2` runs, Then s2 is rebased (journal `land  rebased ...
# commits=1`), main contains both commits, and exit is 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/shwt-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: s1 (first lander) exits 0" \
  "ok  AC2: s2 (rebase-first, disjoint file) exits 0" \
  "ok  AC2: journal names the rebase with commits=1" \
  "ok  AC2: main has both s1's and s2's changes"
