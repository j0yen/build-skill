#!/usr/bin/env bash
# burstvol_ac5_busy_volume_boots_without_it.sh —
# PRD-build-burst-persistent-volume AC5.
#
# Given hcloud reports the volume attached to another server, when up runs, then no attach is attempted, volume busy is journaled naming the server, and the session boots with volume_mounted=false.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC5: up still exits 0 (boots without the volume)" \
  "ok  burstvol AC5: no volume attach call was attempted" \
  "ok  burstvol AC5: journal names the server the volume is attached to" \
  "ok  burstvol AC5: volume state recorded volume_mounted=false"
