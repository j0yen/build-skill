#!/usr/bin/env bash
# reality_ac6_failed_result_drafts_lint_clean_followup.sh —
# PRD-build-post-ship-reality-check AC6.
#
# Given a `reality: failed` result, When the tick continues, Then
# `build-queue/PRD-<slug>-reality-1.md` exists, passes `prd-lint.sh`,
# contains the failing command, an output excerpt, a first why, and one
# `N. P0 —` line per failed acceptance, and the parent's frontmatter has
# `reality_followup:`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reality AC6: reality: failed" \
  "ok  reality AC6: reality_followup: set on the parent" \
  "ok  reality AC6: follow-up file exists" \
  "ok  reality AC6: follow-up passes prd-lint.sh" \
  "ok  reality AC6: follow-up names the failing command and a P0 line" \
  "ok  reality AC6: journal has 'reality  follow-up  drafted'"
