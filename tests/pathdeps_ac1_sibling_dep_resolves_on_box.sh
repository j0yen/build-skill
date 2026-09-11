#!/usr/bin/env bash
# pathdeps_ac1_sibling_dep_resolves_on_box.sh — PRD-build-burst-path-deps AC1.
#
# Given a fixture crate depending on ../sibling by path, When `run` executes
# against the fake box, Then both directories are rsynced and the fake
# remote `cargo metadata` resolves the dependency.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathdeps AC1: run against a crate with a sibling path dep exits 0" \
  "ok  pathdeps AC1: the worktree itself was rsynced" \
  "ok  pathdeps AC1: the sibling path dependency was also rsynced" \
  "ok  pathdeps AC1: cargo metadata really resolved the dependency (no 'failed to load source' error)" \
  "ok  pathdeps AC1: journal names exactly one synced dependency"
