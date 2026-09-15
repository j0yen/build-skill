#!/usr/bin/env bash
# reenable_ac13_parity_baseline_refresh_on_bake.sh — PRD-build-burst-dispatch-reenable AC13.
#
# Given a bake changed the image id, When the next session starts, Then
# the parity baseline is refreshed and the journal has `parity baseline
# refreshed (cause=bake ...)` before any parity comparison, with no
# diff reported for the toolchain change alone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC13a: the stale cached local capture was deleted" \
  "ok  reenable AC13a: journal has parity baseline-refreshed (cause=bake image_id=222)" \
  "ok  reenable AC13a: the tracked baseline image is now the new one" \
  "ok  reenable AC13b: no prior baseline -> the cached local capture is left alone" \
  "ok  reenable AC13b: no baseline-refreshed line was journaled" \
  "ok  reenable AC13b: the tracked baseline image is now recorded" \
  "ok  reenable AC13c: same image -> the cached local capture is left alone" \
  "ok  reenable AC13c: no baseline-refreshed line was journaled" \
  "ok  reenable AC13d: cmd_up's fresh-boot path calls the refresh before scheduling parity" \
  "ok  reenable AC13d: cmd_up's adopt path calls the refresh before scheduling parity"
