#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC6.
#
# Given scripts/skill-prose-lint.sh and a fixture copy of SKILL.md with
# one raw gate-launch.sh ... --scope main block re-added outside the
# section, when the lint runs, then it exits non-zero and prints that
# block's line number; on the shipped SKILL.md it exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC6: lint exits 0 on the shipped SKILL.md" \
  "ok  AC6: lint exits non-zero on the fixture with a raw form re-added" \
  "ok  AC6: lint names the offending line"
