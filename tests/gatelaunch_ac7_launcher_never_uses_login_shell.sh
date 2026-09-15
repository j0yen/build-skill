#!/usr/bin/env bash
# gatelaunch_ac7_launcher_never_uses_login_shell.sh —
# PRD-build-gate-launch-survives-tick AC(g).
#
# gate-launch.sh's own invocation of the unit's command is plain
# `bash -c`, never `bash -lc`/`bash -l` — a login shell re-sources
# ~/.bashrc and can reorder PATH out from under the cargo-route/burst-PATH
# prefix gate-launch.sh built. A grep assertion against the real script
# (comments, which legitimately name the anti-pattern, excluded).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatelaunch-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gate-launch.sh's own invocation never uses bash -l (comments aside)" \
  "ok  gate-launch.sh invokes bash -c (not -lc)"
