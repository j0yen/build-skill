#!/usr/bin/env bash
# provefx_ac12_bake_no_output_flag.sh — PRD-build-burst-prove-forensics
# AC12.
#
# Given a fixture hcloud whose `server create-image` rejects -o with
# exactly `unknown shorthand flag: 'o' in -o` but succeeds without it, When
# bake runs on a fixture session with gate_ready=true, Then the journal has
# `bake done (image_id=…)` and snapshot.json names the fixture image id.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC1: bake exits 0" \
  "ok  reenable AC1: bake prints the new image_id" \
  "ok  reenable AC1: snapshot.json holds a new image_id and the build_skill_sha" \
  "ok  reenable AC1: journal has bake done (image_id=... superseded=none secs=...)" \
  "ok  reenable AC1 / AC12: the create-image call carries no -o/--output flag"
