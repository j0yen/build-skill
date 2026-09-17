#!/usr/bin/env bash
# PRD-build-skill-instruction-single-source AC2.
#
# Given a push_via_branch=true fixture with no landing record and a stub
# gh whose pr view returns a merged loop/S PR with merge sha M, when
# archive-gate.sh <repo> S runs, then state/landings/<repo>/S.json is
# written with merge_sha M and reconstructed_from, and the pinned form is
# launched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/skillsrc-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: exit code is the stub's (0)" \
  "ok  AC2: landing record was written" \
  "ok  AC2: record's merge_sha is the reconstructed one" \
  "ok  AC2: record carries reconstructed_from" \
  "ok  AC2: pinned form launched after reconstruction"
