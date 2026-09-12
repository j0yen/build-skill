#!/usr/bin/env bash
# pathws_ac1_workspace_member_syncs_once.sh — PRD-build-burst-path-deps-
# workspaces AC1.
#
# Given a fake workspace with members a and b where a depends on b by path,
# When `run` executes for a, Then the workspace root is synced once, no
# deps/b exists on the fake box, and the fake `cargo metadata` resolves
# without collision.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathws AC1: run against a workspace member exits 0" \
  "ok  pathws AC1: cargo metadata really resolved the in-workspace sibling" \
  "ok  pathws AC1: the WHOLE workspace root was synced as one tree" \
  "ok  pathws AC1: the member subdirectory was never synced as its own separate source" \
  "ok  pathws AC1: no deps/ mirror was created for the in-workspace sibling"
