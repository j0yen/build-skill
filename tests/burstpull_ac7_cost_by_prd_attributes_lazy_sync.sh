#!/usr/bin/env bash
# burstpull_ac7_cost_by_prd_attributes_lazy_sync.sh — PRD-build-burst-pull-on-demand AC7.
#
# Given a session with skipped and performed pulls, when `cost --by-prd`
# runs, then lazy-pull sync_s appears under the triggering slug (or
# `teardown`) and the conservation check passes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3: cost ledger gains 4 slug rows (incl. teardown sweep) whose eur sums exactly to the session eur" \
  "ok  AC4: cost --by-prd --session exits 0 (conservation check passes)" \
  "ok  burstpull P1 AC7: cost --by-prd table header includes the skip-yield columns"
