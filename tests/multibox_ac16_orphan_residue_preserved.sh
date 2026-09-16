#!/usr/bin/env bash
# multibox_ac16_orphan_residue_preserved.sh — PRD-build-burst-state-keyed-
# by-server-v2 AC16.
#
# Given top-level per-box files whose owner cannot be determined (no
# session.json, no id suffix), When the migration runs, Then they are
# under boxes/_orphan-<ts>/, nothing was deleted, and the journal has
# `state  migrated-orphan`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  multibox AC16: an unattributable residue moved to boxes/_orphan-<ts>/" \
  "ok  multibox AC16: up.lock landed in the orphan dir (not deleted)" \
  "ok  multibox AC16: inflight.log landed in the orphan dir (not deleted)" \
  "ok  multibox AC16: journal has 'state  migrated-orphan'" \
  "ok  multibox AC16: the top-level copy is gone (moved, not copied)"
