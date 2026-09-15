#!/usr/bin/env bash
# reenable_ac7_enable_disable_drop_in.sh — PRD-build-burst-dispatch-reenable AC7.
#
# Given `proof.json` with routed=true younger than 7 days naming the
# image `up` would boot, When `enable` runs, Then the drop-in exists
# with Environment=BUILD_BURST_ENABLED=1, daemon-reload was invoked,
# and burst_configured() returns true in a fresh shell; given a
# missing, stale, routed=false, or different-image proof, Then
# `enable` exits 3 and no drop-in is written. `disable` removes the
# drop-in and journals `disable done (cause=operator)`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC7a: enable exits 0 on a fresh, routed, image-matching proof" \
  "ok  reenable AC7a: the drop-in exists with Environment=BUILD_BURST_ENABLED=1" \
  "ok  reenable AC7a: journal has enable done (proof_ts=... image_id=555777)" \
  "ok  reenable AC7a: burst_configured() reads true in a fresh shell sourcing the drop-in's Environment= line" \
  "ok  reenable AC7b: enable exits 3 with no proof.json" \
  "ok  reenable AC7b: no drop-in was written" \
  "ok  reenable AC7b: journal names the refusal cause" \
  "ok  reenable AC7c: enable exits 3 on a proof older than 7 days" \
  "ok  reenable AC7c: no drop-in was written" \
  "ok  reenable AC7c: journal names the refusal cause" \
  "ok  reenable AC7d: enable exits 3 when proof.routed is false" \
  "ok  reenable AC7d: no drop-in was written" \
  "ok  reenable AC7d: journal names the refusal cause" \
  "ok  reenable AC7e: enable exits 3 when the proof names a different image" \
  "ok  reenable AC7e: no drop-in was written" \
  "ok  reenable AC7e: journal names the refusal cause" \
  "ok  reenable AC7f: disable exits 0" \
  "ok  reenable AC7f: the drop-in no longer exists" \
  "ok  reenable AC7f: journal has disable done (cause=operator)"
