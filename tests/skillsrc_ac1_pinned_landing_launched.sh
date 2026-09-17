#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC1.
#
# Given a fixture repo with push_via_branch=true and a landing record for
# slug S with merge_sha M, when archive-gate.sh <repo> S runs with a stub
# gate-launch, then the stub records --scope main --slug S
# --pinned-landing and the script prints that command and exits with the
# stub's code.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: exit code is the stub's (0)" \
  "ok  AC1: stub recorded --scope main --slug slug-a --pinned-landing" \
  "ok  AC1: archive-gate printed the command it ran"
