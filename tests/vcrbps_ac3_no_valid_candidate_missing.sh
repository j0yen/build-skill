#!/usr/bin/env bash
# vcrbps_ac3_no_valid_candidate_missing.sh — PRD-build-verified-completed-
# realbox-perserver AC3.
#
# Given no box anywhere has a valid proof (flat absent, every per-server
# proof stale, unrouted, or image-mismatched — including an orphan box
# dir with no proof.json inside at all), When check_real_box_evidence
# runs, Then it returns MISSING, unchanged from today, and never crashes
# the glob.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/vcrbps-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC3 flat absent + orphan box dir (no proof.json inside) -> AC2 MISSING, no crash" \
  "ok  AC3 every per-server proof unrouted/stale/mismatched -> AC2 MISSING"
