#!/usr/bin/env bash
# shwt_ac3_land_conflict_exit5.sh — PRD-build-shell-worktree-isolation AC3.
#
# Given s1 landed a change to a shared file and s2 changed the same line,
# When `land <repo> s2` runs, Then exit is 5, the journal has
# `land  conflict  (slug=s2 files=<file>)`, branch autobuilder/s2 still has
# its commit, and main equals s1's landing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/shwt-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: s3 lands cleanly (exit 0)" \
  "ok  AC3: s4's conflicting rebase-land exits 5" \
  "ok  AC3: journal names the conflict and the file" \
  "ok  AC3: autobuilder/s4 branch still has its own commit" \
  "ok  AC3: main is unchanged (still s3's landing)"
