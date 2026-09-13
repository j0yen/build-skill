#!/usr/bin/env bash
# volid_ac8_startup_guard_adopts_or_replaces.sh — PRD-build-burst-volume-
# id-parse AC8.
#
# Given an unattached wm-burst-* volume present at start, when `up` runs,
# then it is adopted (size already matches BURST_VOLUME_GB) or deleted and
# replaced (size mismatch); exactly one volume exists afterwards either
# way, and the journal names which happened.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  volidfix AC8a: up exits 0 and adopts a pre-existing same-size volume" \
  "ok  volidfix AC8a: the adopted volume is the pre-existing one, not a new create" \
  "ok  volidfix AC8a: no volume create call happened during up (only the pre-seed's own)" \
  "ok  volidfix AC8a: journal names the adoption" \
  "ok  volidfix AC8a: exactly one volume exists for this name afterward" \
  "ok  volidfix AC8b: up exits 0 and replaces a size-mismatched pre-existing volume" \
  "ok  volidfix AC8b: the new volume is NOT the old mismatched one" \
  "ok  volidfix AC8b: journal names the size-mismatch replacement" \
  "ok  volidfix AC8b: journal also records the fresh create" \
  "ok  volidfix AC8b: exactly one volume exists for this name afterward" \
  "ok  volidfix AC8b: the old mismatched volume no longer exists"
