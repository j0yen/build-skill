#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC4.
#
# Given fixture (AC1), when gate-launch.sh <repo> --head <sha> --scope
# main --slug S --wait is called without --pinned-landing, then it exits
# non-zero with a message naming archive-gate.sh and launches no unit;
# --main-health and --pinned-landing calls are unaffected.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC4: refusal exits non-zero (6)" \
  "ok  AC4: refusal names archive-gate.sh" \
  "ok  AC4: no inflight marker was written (refused before launch)" \
  "ok  AC4: --pinned-landing calls are unaffected" \
  "ok  AC4: --main-health calls are unaffected"
