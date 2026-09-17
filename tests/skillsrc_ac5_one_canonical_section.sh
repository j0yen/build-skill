#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC5.
#
# Given the shipped SKILL.md, when grepped for the raw main-gate command
# form over fenced blocks outside the section marked
# <!-- single-source: archive-gate -->, then it matches nothing, the
# canonical section exists exactly once, and each of the seven former
# sites contains a reference to it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5: marker appears exactly once" \
  "ok  AC5: heading appears exactly once" \
  "ok  AC6: lint exits 0 on the shipped SKILL.md"
