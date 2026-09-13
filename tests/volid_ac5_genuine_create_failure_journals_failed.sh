#!/usr/bin/env bash
# volid_ac5_genuine_create_failure_journals_failed.sh — PRD-build-burst-
# volume-id-parse AC5.
#
# Given a create that exits non-zero, when `up` runs, then
# volume-create-failed is journaled and no delete is attempted —
# volume-create-unwound never fires for a create that never happened.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  volidfix AC5: up still exits 0 (boots on root disk) when create itself fails" \
  "ok  volidfix AC5: volume-create-failed is journaled" \
  "ok  volidfix AC5: no volume delete call was attempted (nothing was created)" \
  "ok  volidfix AC5: volume-create-unwound is never journaled for a failed create"
