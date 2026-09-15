#!/usr/bin/env bash
# reenable_ac8_fail_closed_tick_fallback.sh — PRD-build-burst-dispatch-reenable AC8.
#
# Given burst_configured() true and `up` (or `verify`, or a
# gate_ready=false provision, or `pull`) failing for a branch, When the
# tick handles that branch, Then the branch's cargo runs locally, the
# journal has `burst fallback (cause=...)`, and the PRD's claim state
# is unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC8a: run exits 3 when up itself fails" \
  "ok  reenable AC8a: journal has run fallback (cause=up-failed worktree=" \
  "ok  reenable AC8b: run exits 3 when verify fails" \
  "ok  reenable AC8b: journal has run fallback (cause=verify-failed server_id=" \
  "ok  reenable AC8c: pull exits 3 when the rsync-down fails" \
  "ok  reenable AC8c: journal has pull fallback (cause=rsync-failed worktree="
