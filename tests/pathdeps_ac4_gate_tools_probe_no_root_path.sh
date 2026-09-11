#!/usr/bin/env bash
# pathdeps_ac4_gate_tools_probe_no_root_path.sh — PRD-build-burst-path-deps
# AC4.
#
# Given a fake box where a tool exists only under /root/.local/bin, When
# the gate-tools probe runs as the build user, Then that tool reads MISSING
# and gate_ready=false names it.
#
# The fake ssh's own `# gate-tools-probe` case is fully canned (a per-test
# FAKE_SSH_GATE_TOOLS_MISSING list, never a real PATH lookup) and so cannot
# simulate "installed only under root" end to end — this AC is instead
# proven the way burst-lane_ac2 proved its own sccache-export invariant:
# structurally (the PATH-construction line no longer unconditionally
# includes root's paths) AND dynamically, by inspecting the ACTUAL command
# string burst-lane.sh sent over ssh for this probe (which is real
# regardless of the fake's canned reply) and confirming it carries no
# /root reference for the build user.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  pathdeps AC4: the gate-tools probe ran as build@" \
  "ok  pathdeps AC4: the probe's own PATH export carries no /root reference" \
  "ok  pathdeps AC4 (structural): gate_tools_probe's PATH export is now conditional on REMOTE_USER, not unconditionally including root's paths"
