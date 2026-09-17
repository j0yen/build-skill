#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC9.
#
# Given scripts/skill-single-source-selftest.sh with fixtures for
# AC1-AC8, when it runs on RedBaron, then it ends PASS with 0 FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "skill-single-source-selftest: PASS"
