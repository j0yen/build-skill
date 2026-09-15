#!/usr/bin/env bash
# durheal_ac4_heal_requeues_file_before_cache.sh — PRD-build-
# classification-durable-heal AC4.
#
# Given a parked fixture PRD that passes lint and a manifest cache saying
# `needs_classification`, When `manifest-invariants.sh` runs, Then the
# file reads `queued` and is committed before the cache entry changes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/durheal-ac-common.sh"
run_and_expect_labels "$HERE/manifest-inv_ac2_needs_classification_lint_pass_heals.sh" \
  "ok  entry healed to queued" \
  "ok  reason field cleared" \
  "ok  PRD file itself reads Status: queued (not just the cache)" \
  "ok  the requeue landed a commit"
