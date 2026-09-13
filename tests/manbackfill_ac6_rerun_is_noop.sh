#!/usr/bin/env bash
# manbackfill_ac6_rerun_is_noop.sh —
# PRD-build-archive-manifest-backfill AC6: given a slug already
# backfilled and flipped by a prior run, when archive-commit.sh runs
# again, then it exits 0 without a second line or a second commit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/manbackfill-ac-common.sh"
run_suite_and_expect_labels \
  "ok  MANBACKFILL AC6: re-run exits 0" \
  "ok  MANBACKFILL AC6: re-run adds no new commit" \
  "ok  MANBACKFILL AC6: exactly one line for the slug (no dup)"
