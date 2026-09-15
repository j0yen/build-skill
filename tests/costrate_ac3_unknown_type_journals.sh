#!/usr/bin/env bash
# costrate_ac3_unknown_type_journals.sh — PRD-build-burst-cost-rate-by-type
# AC3.
#
# Given a server type not in the price table and no env override, When a
# session tears down, Then it journals a rate-unknown line naming the type
# and the 0.47 fallback, and prices the teardown at that fallback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  costrate AC3: idle-guard tears down the unknown-type box" \
  "ok  costrate AC3: an unknown type journals rate-unknown naming the fallback" \
  "ok  costrate AC3: the teardown still prices at the 0.47 fallback"
