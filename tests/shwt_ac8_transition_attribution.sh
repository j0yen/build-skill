#!/usr/bin/env bash
# shwt_ac8_transition_attribution.sh — PRD-build-shell-worktree-isolation AC8.
#
# Given a fixture main with dirty files attributable to slug tr1 (its
# branch exists) and unattributable dirty files, When the transition step
# runs, Then tr1's file is committed on autobuilder/tr1, the unattributable
# files are committed on transition/<ts>, main is clean, and the journal
# has one `worktree  transition` line naming the total dirty file count.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/shwt-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC8: transition exits 0" \
  "ok  AC8: main is clean after transition" \
  "ok  AC8: journal names dirty_files=3" \
  "ok  AC8: attributed file's dirty edit reached autobuilder/tr1" \
  "ok  AC8: an unattributable-files transition/<ts> branch was created" \
  "ok  AC8: b.sh landed on the transition branch" \
  "ok  AC8: c.sh landed on the transition branch"
