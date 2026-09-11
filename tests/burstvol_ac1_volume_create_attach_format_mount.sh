#!/usr/bin/env bash
# burstvol_ac1_volume_create_attach_format_mount.sh —
# PRD-build-burst-persistent-volume AC1.
#
# Given no volume exists, when up runs, then it creates, attaches, formats, and mounts the volume, journaling create then attach.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstvol AC1: up exits 0" \
  "ok  burstvol AC1: exactly one volume create call" \
  "ok  burstvol AC1: exactly one volume attach call" \
  "ok  burstvol AC1: the mount+format round trip ran as root" \
  "ok  burstvol AC1: journal has both a volume created and a volume attached line" \
  "ok  burstvol AC1: volume created precedes volume attached"
