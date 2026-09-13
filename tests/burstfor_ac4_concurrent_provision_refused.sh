#!/usr/bin/env bash
# burstfor_ac4_concurrent_provision_refused.sh — PRD-build-burst-provision-forensics AC4.
#
# Given a provision holding the lock, when a second provision starts for
# the same lane, then it exits non-zero within 5s and journals
# provision-refused (lock-held pid=N).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burstfor-ac-common.sh"
run_burstfor_suite_and_expect_labels \
  "ok  AC4: second provision exits nonzero" \
  "ok  AC4: second provision refused within 5s" \
  "ok  AC4: journal names provision-refused with the holder's pid"
