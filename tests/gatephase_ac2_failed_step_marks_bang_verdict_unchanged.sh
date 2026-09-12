#!/usr/bin/env bash
# gatephase_ac2_failed_step_marks_bang_verdict_unchanged.sh —
# PRD-build-gate-phase-timing AC2.
#
# Given a fake step that exits non-zero after 2s, when the gate runs, then
# that phase reads <name>:2! and the verdict is the same as without timers
# (the fake gate's own scripted exit code, unaffected by the failing
# vti-plan step elsewhere in the sequence).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatephase-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: extend-gate.sh's exit code mirrors the fake gate's own (0) despite vti-plan failing" \
  "ok  AC2: failed step reads vti-plan:<s>! (got 2!)"
