#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC3.
#
# Given a direct-push fixture (push_via_branch=false), when
# archive-gate.sh <repo> S runs, then the stub records --head <landed
# sha> --scope main --slug S without --pinned-landing, and the journal
# line is byte-identical in shape to the pre-PRD selftest baseline.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: exit code is the stub's (0)" \
  "ok  AC3: stub recorded plain form with the landed sha, no --pinned-landing" \
  "ok  AC3: journal line shape matches the baseline (repo slug + action)"
