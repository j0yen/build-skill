#!/usr/bin/env bash
# volid_ac3_unparseable_create_is_unwound.sh — PRD-build-burst-volume-id-
# parse AC3.
#
# Given a fixture create that exits 0 but returns output the parser
# cannot read, when `up` runs, then the volume is located by name and
# deleted, and volume-create-unwound (name=... id=... cause=...) is
# journaled — never volume-create-failed, since the create itself
# succeeded.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  volidfix AC3/4: up still exits 0, booting on root disk" \
  "ok  volidfix AC3: volume-create-unwound is journaled with name, id, and cause" \
  "ok  volidfix AC3: volume-create-failed is never journaled for this case"
