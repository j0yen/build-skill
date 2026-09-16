#!/usr/bin/env bash
# shwt_ac5_state_dir_isolation.sh — PRD-build-shell-worktree-isolation AC5.
#
# Given a fixture selftest run from inside a worktree with the printed env
# exported, When it writes state and journal lines, Then <worktree>/state/
# gained files and the fixture's "production" state dir and journal gained
# none.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/shwt-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5: worktree state/ gained the probe file" \
  "ok  AC5: fixture's 'production' state dir gained nothing" \
  "ok  AC5: fixture's 'production' journal gained no lines"
