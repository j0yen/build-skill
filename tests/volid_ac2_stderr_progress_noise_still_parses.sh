#!/usr/bin/env bash
# volid_ac2_stderr_progress_noise_still_parses.sh — PRD-build-burst-volume-
# id-parse AC2.
#
# Given a fixture hcloud whose volume-create writes action-progress lines
# to stderr and valid JSON to stdout, when `up` runs, then the id is
# parsed correctly and volume.json records it. This is the exact shape
# that broke in production: `2>&1` used to merge this stderr noise into
# the parse target.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  volidfix AC2: up exits 0 when create emits stderr progress noise" \
  "ok  volidfix AC2: the id is parsed correctly from stdout alone" \
  "ok  volidfix AC2: no volume-create-failed line was journaled despite stderr noise"
