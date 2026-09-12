#!/usr/bin/env bash
# archatomic_ac5_sibling_pull_survives.sh —
# PRD-build-archive-atomic-commit AC5: given a sibling working copy with
# an uncommitted edit to an unrelated PRD and an origin one commit ahead,
# when lane-claim.sh runs its pull in that copy, then the pull succeeds,
# the sibling's edit is still present afterwards, and the claim proceeds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/archatomic-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5: claim succeeds despite the dirty sibling file" \
  "ok  AC5: claim message reports claimed" \
  "ok  AC5: sibling's own edit is still present afterwards" \
  "ok  AC5: sibling's edit stayed uncommitted (not swept in)" \
  "ok  AC5: the incoming commit was pulled in"
