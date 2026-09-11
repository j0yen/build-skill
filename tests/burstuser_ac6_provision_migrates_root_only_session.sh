#!/usr/bin/env bash
# burstuser_ac6_provision_migrates_root_only_session.sh — PRD-build-burst-
# unprivileged-user AC6.
#
# Given a live root-only session, When `provision` runs post-ship, Then the
# user is created, session state records remote_user=build, a still-dirty
# worktree's remote tree is copied from the old root-owned path into the
# new one, and a following `run` routes as build without a reboot.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstuser AC6: session.json now records remote_user=build" \
  "ok  burstuser AC6: journal records the user migration (root -> build)" \
  "ok  burstuser AC6: journal records the worktree's tree migrated, not gone cold" \
  "ok  burstuser AC6: the worktree's remote artifact landed in the NEW (build) tree" \
  "ok  burstuser AC6: the migration copy ran over root ssh (only user who can read the old tree)" \
  "ok  burstuser AC6: a following run exits cleanly without a second up" \
  "ok  burstuser AC6: that run routed as build@, no reboot needed" \
  "ok  burstuser AC6: that run made no root@ call"
