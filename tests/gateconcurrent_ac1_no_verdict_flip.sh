#!/usr/bin/env bash
# gateconcurrent_ac1_no_verdict_flip.sh — PRD-build-extend-gate-concurrent-isolation AC1.
#
# Given two extend-gate.sh invocations launched within 1s of each other
# against the same fixture repo at the same HEAD, when both complete, then
# both report identical pass=N block=M counts and identical blocking-receipt
# names (no flip).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gateconcurrent-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1: run1 exits 0 (pass or delta-pass/block, but completes)" \
  "ok  AC1: run2 exits 0 (pass or delta-pass/block, but completes)" \
  "ok  AC1: neither run timed out (rc != 124/137)" \
  "ok  AC1: run1 produced a gate verdict line" \
  "ok  AC1: run2 produced a gate verdict line" \
  "ok  AC1: both invocations report an IDENTICAL gate line (no flip at the same HEAD)" \
  "AC1/AC2: total wall time bounded (no deadlock"
