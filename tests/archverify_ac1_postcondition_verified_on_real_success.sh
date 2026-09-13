#!/usr/bin/env bash
# archverify_ac1_postcondition_verified_on_real_success.sh —
# PRD-build-archive-verify-before-shipped acceptance criterion 1: given
# archive-commit.sh completes its git-mv+commit+push sequence for real,
# when it exits, then built-prds/PRD-<slug>.md exists, build-queue/ does
# not, and the commit is reachable from origin — verified by the script
# itself before it exits 0. This is the same clean-archive fixture
# archive-commit-selftest.sh's own AC1 already exercises end to end
# (unmodified by this PRD); the new postcondition check added here runs
# silently in that path and must never turn an honest success into a
# false failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archverify-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: archive-commit exits 0" \
  "ok  AC1: build-queue/PRD-clean1.md is gone" \
  "ok  AC1: MANIFEST.md line flipped to shipped" \
  "ok  AC1: exactly one new commit reached origin"
