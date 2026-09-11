#!/usr/bin/env bash
# burstuser_ac3_run_routes_as_build_no_cargo_to_root.sh — PRD-build-burst-
# unprivileged-user AC3.
#
# Given a session up, When `run <worktree> -- cargo test` executes, Then the
# remote command runs as build under $REMOTE_ROOT/<key> and no fake root
# call carries cargo.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  burstuser AC3: the remote cargo call targeted build@" \
  "ok  burstuser AC3: the remote path is under \$REMOTE_ROOT (which itself defaults to \$REMOTE_HOME/build — see the _debug-remote-config check below)" \
  "ok  burstuser AC3: no fake root ssh call carries cargo" \
  "ok  burstuser AC3: no fake root ssh call happened at all during run" \
  "ok  burstuser AC3: the worktree rsync-up targeted build@" \
  "ok  burstuser AC3: no rsync call targeted root@"
