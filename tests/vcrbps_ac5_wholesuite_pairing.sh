#!/usr/bin/env bash
# vcrbps_ac5_wholesuite_pairing.sh — PRD-build-verified-completed-realbox-
# perserver AC5.
#
# Given an AC line whose Then clause names a selftest script and no per-AC
# test file exists for that number, When --derive runs, Then it pairs that
# AC against the named script's own last-recorded exit code (a fresh,
# this-PRD-slug-scoped receipt) rather than a same-numbered file belonging
# to an unrelated PRD — and does NOT fabricate a pairing when no receipt,
# or only a nonzero-exit receipt, exists yet.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/vcrbps-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC5a whole-suite AC with no receipt yet -> MISSING, not falsely paired" \
  "ok  AC5b receipted nonzero exit -> AC3 still not paired" \
  "ok  AC5c receipted exit 0 -> AC3 PAIRED via whole-suite"
