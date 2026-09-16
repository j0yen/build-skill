#!/usr/bin/env bash
# multibox_ac12_full_surface_migration.sh — PRD-build-burst-state-keyed-by-
# server-v2 AC12.
#
# Given a pre-ship top-level state directory populated with every per-box
# name in requirement 1 for box 111, When the first command runs, Then
# every per-box name is under boxes/111/, every lane-wide name is still
# top-level, the journal names the exact moved count, and
# `find state/burst-lane -maxdepth 1` shows no per-box name.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC12: every per-box name for box 111 landed under boxes/111/" \
  "ok  multibox AC12: snapshot.json (lane-wide) stayed top-level" \
  "ok  multibox AC12: parity-baseline-image (lane-wide) stayed top-level" \
  "ok  multibox AC12: decisions.jsonl (lane-wide) stayed top-level" \
  "ok  multibox AC12: provision.lock (lane-wide) stayed top-level" \
  "ok  multibox AC12: journal names the exact moved count (13 per-box entries)" \
  "ok  multibox AC12: find -maxdepth 1 shows no per-box name left at the top level"
