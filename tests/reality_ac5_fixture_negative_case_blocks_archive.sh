#!/usr/bin/env bash
# reality_ac5_fixture_negative_case_blocks_archive.sh —
# PRD-build-post-ship-reality-check AC5.
#
# Given a fixture-only test suite with no failure-mode case, When the
# archive gate evaluates it, Then the archive blocks naming the rule;
# adding one failure-mode case unblocks it. Also covers prd-lint.sh's
# pre-ship warning on a happy-path-only AC mention.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC5 (real failure-mode case: a success-only diff) — verified-completed blocks archive naming the rule" \
  "ok  AC5: prd-lint.sh warns selftest-no-negative-case on a happy-path-only AC mention"
