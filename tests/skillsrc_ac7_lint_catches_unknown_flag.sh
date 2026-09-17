#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC7.
#
# Given a fixture SKILL.md whose fenced block uses
# gate-launch.sh --no-such-flag, when the lint runs, then it exits
# non-zero naming the flag and the script; and run-selftests.sh lists the
# lint (via this PRD's selftest) so the build-skill gate runs it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC7: lint exits non-zero" \
  "ok  AC7: lint names the flag" \
  "ok  AC7: lint names the script" \
  "ok  AC7: run-selftests.sh lists this selftest"
