#!/usr/bin/env bash
# reenable_ac3_up_resolves_baked_image.sh — PRD-build-burst-dispatch-reenable AC3.
#
# Given a `snapshot.json`, When `up` runs, Then the fake `hcloud server
# create` receives `--image <snapshot.json id>` and the journal has
# `up image (id=... source=baked)`; given no `snapshot.json`, Then
# source is `env` or `default` and behaviour is unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC3a: up still exits 0 with a baked snapshot.json present" \
  "ok  reenable AC3a: fake hcloud server create received --image 999888" \
  "ok  reenable AC3a: journal has up image (id=999888 source=baked)" \
  "ok  reenable AC3b: up exits 0 with no snapshot.json (unchanged behavior)" \
  "ok  reenable AC3b: up still prints 'up: <id> <ip>'" \
  "ok  reenable AC3b: fake hcloud server create received --image 427125061" \
  "ok  reenable AC3b: journal has up image (id=427125061 source=env)"
