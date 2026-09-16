#!/usr/bin/env bash
# vcrbps_ac1_realbox_perserver_only.sh — PRD-build-verified-completed-
# realbox-perserver AC1.
#
# Given state/burst-lane/proof.json absent and
# state/burst-lane/boxes/<id>/proof.json present with routed:true, a
# matching image_id, and ts within 7 days, When check_real_box_evidence
# runs, Then it returns that evidence in the same output shape as today's
# flat-path case.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/vcrbps-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC1 per-server-only proof (flat absent) -> AC2 PAIRED via real-box" \
  "ok  AC1 evidence names the per-server path, not the retired flat path"
