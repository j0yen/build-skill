#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC8.
#
# Given every prompt file under the build skill that branch agents
# receive, when grepped for the raw main-gate form, then none matches,
# and any that previously quoted the command now quotes the
# archive-gate.sh call. This build skill has no standalone prompt
# template files (branch-agent dispatch text is composed from SKILL.md
# at dispatch time, per SKILL.md's own Dispatch section) — the nearest
# doc/template surfaces (templates/, docs/) are what this checks.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC8: templates/ and docs/ are clean of the raw form"
