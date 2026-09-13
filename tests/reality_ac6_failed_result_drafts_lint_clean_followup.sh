#!/usr/bin/env bash
# reality_ac6_failed_result_drafts_lint_clean_followup.sh —
# PRD-build-post-ship-reality-check AC6.
#
# Given a failed reality run, When the tick completes, Then a follow-up
# PRD sits queued carrying the failing command, output excerpt, and the
# shipped slug in its lineage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/reality-check-ac-common.sh"
run_reality_suite_and_expect_labels \
  "ok  AC6/regression: a reachable box still runs live and a real failure is recorded" \
  "ok  AC6: reality_followup: set on the parent" \
  "ok  AC6: follow-up file exists" \
  "ok  AC6: follow-up passes prd-lint.sh" \
  "ok  AC6: follow-up names the failing command and carries a P0 line" \
  "ok  AC6: journal has 'reality  follow-up  drafted'"
