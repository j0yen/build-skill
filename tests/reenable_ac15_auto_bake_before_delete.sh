#!/usr/bin/env bash
# reenable_ac15_auto_bake_before_delete.sh — PRD-build-burst-dispatch-reenable AC15.
#
# Given a session whose provision journaled at least one install-start
# and ended gate_ready=true, When `down` proceeds to delete, Then
# `bake` ran first and snapshot.json names the new image; given a
# session with zero install-start lines, Then `down` deletes without
# baking; given a third baked image, Then the oldest is journaled
# `bake superseded (... delete=operator)` and no image is deleted by
# the lane.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC15a setup: session is gate_ready=true" \
  "ok  reenable AC15a setup: exactly one install-start line" \
  "ok  reenable AC15a: journal has the auto-bake trigger naming the install count" \
  "ok  reenable AC15a: journal has bake done" \
  "ok  reenable AC15a: snapshot.json now names the new image" \
  "ok  reenable AC15b setup: zero install-start lines" \
  "ok  reenable AC15b: no auto-bake was journaled" \
  "ok  reenable AC15b: no bake done was journaled" \
  "ok  reenable AC15b: no snapshot.json was written" \
  "ok  reenable AC15d: auto_bake_before_delete is wired into teardown_and_delete before destroy_verify" \
  "ok  reenable AC15c: bake against an already-full history still exits 0" \
  "ok  reenable AC15c: the new bake's own id is neither of the two prior ones" \
  "ok  reenable AC15c: the bake journals the second (most recent) prior image as superseded=... in bake done" \
  "ok  reenable AC15c: the bake journals the first (oldest) prior image as superseded, delete=operator" \
  "ok  reenable AC15c: snapshot.json's baked_history now holds exactly the two most recent images" \
  "ok  reenable AC15c: no hcloud image delete call was ever made by the lane"
