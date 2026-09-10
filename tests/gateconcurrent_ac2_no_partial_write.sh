#!/usr/bin/env bash
# gateconcurrent_ac2_no_partial_write.sh — PRD-build-extend-gate-concurrent-isolation AC2.
#
# Given the same concurrent scenario, when inspecting each invocation's
# receipts directory during the run (a sleep-instrumented fixture
# producer), then neither directory ever contains a partially-written file
# from the other invocation — proven here via the fixture's own
# scripts/audit.sh start/end markers: the two invocations' producer-writing
# windows never overlap in wall-clock time.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gateconcurrent-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2: exactly 2 audit.sh producer windows were recorded (one per invocation)" \
  "ok  AC2: second invocation's producer phase starts only after the first's ends (no overlap)" \
  "ok  AC2: distinct PIDs ran the two producer phases (genuinely two separate invocations)"
