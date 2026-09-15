#!/usr/bin/env bash
# boxslots_ac1_up_probes_box_records_fields.sh — PRD-build-burst-run-slots-from-box AC1.
#
# Given a fixture box answering 32 cores / 128 GB / 600 GB, When `up`
# completes, Then session.json carries box_cores=32, box_mem_gb=128,
# box_disk_gb=600 and the journal has `up  slots  (cap=8 source=box …)`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  boxslots AC1: session.json carries box_cores=32" \
  "ok  boxslots AC1: session.json carries box_mem_gb=128" \
  "ok  boxslots AC1: session.json carries box_disk_gb=600" \
  "ok  boxslots AC1: journal names cap=8 source=box bound=cpu"
