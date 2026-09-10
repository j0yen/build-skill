#!/usr/bin/env bash
# gateconcurrent_ac3_bounded_fail_closed.sh — PRD-build-extend-gate-concurrent-isolation AC3.
#
# Given a gate invocation that cannot acquire producer access within the
# configured ceiling, when it times out, then it exits non-zero with a
# message naming the contending PID and does NOT emit a pass=.../block=...
# verdict line at all (fail-closed, not fail-wrong).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gateconcurrent-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3 setup: external holder process is alive" \
  "AC3 setup: fuser confirms the known holder pid (" \
  "ok  AC3: contended invocation exits non-zero" \
  "ok  AC3: contended invocation exits with the documented lock-contention code (4)" \
  "ok  AC3: failure message names the reserved phrase producer-lock-contended" \
  "ok  AC3: failure message names a pid=" \
  "AC3: named pid includes the actual known external holder (" \
  "ok  AC3: no gate verdict line was ever printed (fail-closed, not fail-wrong)" \
  "AC3: bounded wait — completed near the 2s ceiling"
