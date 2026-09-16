#!/usr/bin/env bash
# gatefirst_ac5_rebase_and_regate_loop.sh — PRD-build-gate-before-land AC5.
#
# Given exit 6, When the caller runs the rebase-and-regate loop, Then the
# worktree is rebased onto Y, the branch gate re-runs, land --gated-at Y
# succeeds, and the sidecar records one retry; given three consecutive
# stale bases, Then the PRD is blocked: land-retries-exhausted with three
# main shas recorded and main unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_gatethenland_and_expect_labels \
  "ok  AC3: gate-then-land exits 0 (eventually landed)" \
  "ok  AC3: stdout printed the landed sha (40 hex chars)" \
  "ok  AC3: exactly 2 stale-base-retry journal lines" \
  "ok  AC3: exactly 1 'landed' journal line" \
  "ok  AC5: gate-then-land exits 6 (land-retries-exhausted)" \
  "ok  AC5: stderr names land-retries-exhausted" \
  "ok  AC5: a land-retries-exhausted journal line exists" \
  "ok  AC5: 3 main shas were recorded" \
  "ok  AC5: the branch itself never merged onto main (no 'landed' line)"
