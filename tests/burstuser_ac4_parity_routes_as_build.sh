#!/usr/bin/env bash
# burstuser_ac4_parity_routes_as_build.sh — PRD-build-burst-unprivileged-user
# AC4 (routing half — see the PRD's own deferred_acs/mock_justifications for
# why the "zero diffs against the live mcphost repo on a real box" half of
# this AC is deferred to the first live post-ship parity run instead).
#
# Given a session up, When `parity` runs, Then its remote
# `cargo test --workspace` call routes as build@, never root@ — the exact
# identity change that made `checkcompat_ac02_ac03` fail under root.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstuser AC4: parity's remote cargo test call routed as build@" \
  "ok  burstuser AC4: no fake root ssh call happened during parity"
