#!/usr/bin/env bash
# burstpull_ac6_selftest_all_green.sh — PRD-build-burst-pull-on-demand AC6.
#
# Given the selftest suite, when it runs, then the new burstpull fixtures
# pass and all pre-existing (PRD-build-burst-lane-ccx53 /
# PRD-build-burst-parallel-runs / PRD-build-cost-attribution) assertions
# stay green in the same process — run_suite_and_expect_labels already
# requires the whole suite to exit 0; the labels below spot-check that both
# an old-contract assertion and a representative spread of new burstpull
# assertions are present in that one green run, so a future edit that
# quietly drops either half's coverage fails this file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  first up creates a server (exit 0)" \
  "ok  AC6: exactly one daily burst-cost rollup line after two down calls same day" \
  "ok  no pull ran between two consecutive remote runs (AC1)" \
  "ok  burstpull AC2: exactly one pull attribution row, trigger=local-read, reading slug (req 2)" \
  "ok  burstpull AC5: explicit pull is refused while the worktree lock is held" \
  "ok  burstpull AC4: teardown still deletes cleanly despite one cold + one busy worktree" \
  "ok  burstpull P1 AC7: cost --by-prd table header includes the skip-yield columns" \
  "ok  burstpull P1 AC8: daily rollup line names pulls skipped and GB saved"
