#!/usr/bin/env bash
# reenable_ac1_bake_creates_new_image.sh — PRD-build-burst-dispatch-reenable AC1.
#
# Given an active session with gate_ready=true and sandbox_ok=true and a
# fake `hcloud` that answers `create-image` on stdout, When
# `burst-lane.sh bake` runs, Then `snapshot.json` holds the new image_id
# and build_skill_sha, the journal has `bake done (image_id=...
# superseded=... secs=...)`, and the credential shred ran before
# `create-image`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC1 setup: session is gate_ready=true after up" \
  "ok  reenable AC1 setup: session is sandbox_ok=true after up" \
  "ok  reenable AC1 setup: the gate credential is present before bake" \
  "ok  reenable AC1: bake exits 0" \
  "ok  reenable AC1: bake prints the new image_id" \
  "ok  reenable AC1: snapshot.json holds a new image_id and the build_skill_sha" \
  "ok  reenable AC1: journal has bake done (image_id=... superseded=none secs=...)" \
  "ok  reenable AC1: the credential was shredded (no longer present after bake)" \
  "ok  reenable AC1: the credential shred is journaled before bake done (shred ran first)" \
  "ok  reenable AC1: exactly one server create-image call happened" \
  "ok  reenable AC1 / AC12: the create-image call carries no -o/--output flag"
