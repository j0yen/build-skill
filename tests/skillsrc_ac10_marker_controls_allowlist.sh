#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC10.
#
# Given the canonical section's heading is renamed but its marker comment
# kept, when the lint runs, then it still allowlists the section; with
# the marker removed, the lint fails naming the missing marker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC10: renamed heading with marker kept still lints clean" \
  "ok  AC10: marker removed fails the whole lint" \
  "ok  AC10: failure names the missing marker"
