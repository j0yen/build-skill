#!/usr/bin/env bash
# durheal_ac3_requeue_prd_transitions.sh — PRD-build-classification-
# durable-heal AC3.
#
# Given a parked fixture PRD, When `requeue-prd.sh <slug> "test"` runs,
# Then the file reads `Status: queued`, the first iter_log line starts
# with `requeued: test`, and exactly one new commit exists; When it runs
# again, Then no new commit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/durheal-ac-common.sh"
run_and_expect_labels "$HERE/../scripts/requeue-prd-selftest.sh" \
  "ok  AC3: exits 0" \
  "ok  AC3: Status is queued" \
  "ok  AC3: first iter_log line starts with requeued: test" \
  "ok  AC3: exactly one new commit reached origin" \
  "ok  AC3: second call makes no new commit"
