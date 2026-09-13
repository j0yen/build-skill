#!/usr/bin/env bash
# volid_ac1_clean_stdout_parses.sh — PRD-build-burst-volume-id-parse AC1.
#
# Given a fixture hcloud whose volume-create returns well-formed JSON on
# stdout, when `up` runs, then the id is parsed, volume.json records it,
# and no volume-create-failed line is journaled.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  volidfix AC1: up exits 0 against a clean create" \
  "ok  volidfix AC1: volume.json recorded the parsed id" \
  "ok  volidfix AC1: no volume-create-failed line was journaled"
