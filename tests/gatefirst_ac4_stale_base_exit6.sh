#!/usr/bin/env bash
# gatefirst_ac4_stale_base_exit6.sh — PRD-build-gate-before-land AC4.
#
# Given a branch gated at X and main now at Y, When `land --gated-at X`
# runs, Then it exits 6 with land-stale-base (gated_at=X main=Y), main is
# unchanged, and the lock was released.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_gatedland_and_expect_labels \
  "ok  AC4: land exits 6 (land-stale-base)" \
  "ok  AC4: message names land-stale-base with both shas" \
  "ok  AC4: main is unchanged (still at the sibling's commit)" \
  "ok  AC4: the branch still exists (worktree/commits intact, not landed)"
