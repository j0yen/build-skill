#!/usr/bin/env bash
# burstvol_ac2_existing_labeled_volume_skips_format.sh —
# PRD-build-burst-persistent-volume AC2.
#
# Given a volume already exists with a filesystem label, when up runs, then no create/format call is made, only attach.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC2: up exits 0 against a pre-existing, already-formatted volume" \
  "ok  burstvol AC2: no volume create call during this up (only the pre-seed's own)" \
  "ok  burstvol AC2: journal has volume attached, never volume created"
