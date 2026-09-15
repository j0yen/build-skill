#!/usr/bin/env bash
# reenable_ac4_baked_boot_zero_installs_or_bake_stale.sh — PRD-build-burst-dispatch-reenable AC4.
#
# Given a baked boot whose probe reports every tool present, When
# provisioning runs, Then the journal has zero `install-start` lines
# and `provision done (gate_ready=true ...)`; given one tool missing,
# Then exactly one `bake-stale (tool=...)` line precedes its install.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  reenable AC4a: a baked boot with every tool present reaches gate_ready=true" \
  "ok  reenable AC4a: zero install-start lines on an all-present baked boot" \
  "ok  reenable AC4a: journal names the boot as gate_ready=true" \
  "ok  reenable AC4b: exactly one bake-stale line (tool=jq)" \
  "ok  reenable AC4b: exactly one install-start line (tool=jq)" \
  "ok  reenable AC4b: bake-stale precedes install-start"
