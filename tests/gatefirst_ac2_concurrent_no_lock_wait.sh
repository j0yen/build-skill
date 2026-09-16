#!/usr/bin/env bash
# gatefirst_ac2_concurrent_no_lock_wait.sh — PRD-build-gate-before-land AC2.
#
# Given two worktrees on the same crate gating concurrently with
# --scope branch, When both run, Then both complete with lock_wait=0s,
# neither's receipts contain the other's slug, and each verdict matches a
# solo run of the same tree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_concurrent_and_expect_labels \
  "ok  AC1: both invocations report an IDENTICAL gate line (no flip at the same HEAD)" \
  "ok  AC2: exactly 2 audit.sh producer windows were recorded (one per invocation)" \
  "ok  AC2: second invocation's producer phase starts only after the first's ends (no overlap)" \
  "ok  AC2: distinct PIDs ran the two producer phases (genuinely two separate invocations)" \
  "ok  AC1/AC2: total wall time bounded (no deadlock, < 2x per-run timeout)"
