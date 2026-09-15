#!/usr/bin/env bash
# durheal_ac2_reproduced_claim_commits.sh — PRD-build-classification-
# durable-heal AC2.
#
# Given a fixture PRD whose named lint id IS currently failing (here:
# `vision-missing`, since the fixture has no `Vision:` line), When
# mark-needs-classification.sh runs with that reason, Then the file reads
# `needs_classification`, the iter_log line ends with `lint_rc=1`, and one
# commit exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/durheal-ac-common.sh"
run_and_expect_labels "$HERE/../scripts/mark-needs-classification-selftest.sh" \
  "ok  gate-reproduce: exits 0" \
  "ok  gate-reproduce: Status is needs_classification" \
  "ok  gate-reproduce: iter_log ends with lint_rc=1"
