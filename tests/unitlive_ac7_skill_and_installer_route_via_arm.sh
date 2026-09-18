#!/usr/bin/env bash
# unitlive_ac7_skill_and_installer_route_via_arm.sh — PRD-buildloop-unit-liveness AC7.
#
# Given the shipped docs/operator.md (PRD-build-branch-contract-split moved
# the re-arm/restart runbook text out of SKILL.md — SKILL.md is now a
# 200-line index with no re-arm prose of its own) and
# carbon-lane-install.sh, when grepped, then the restart text names
# loop-arm.sh and the installer contains no standalone
# `enable --now claude-build.path`. Unlike the other unitlive wrappers
# this is a direct static-content check (there is no fake-systemctl
# behavior to exercise) rather than a re-run of unitlive-selftest.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail=0
ok() { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

if grep -q "loop-arm.sh" "$SKILL_DIR/docs/operator.md"; then
  ok "unitlive_ac7a: docs/operator.md restart text names loop-arm.sh"
else
  bad "unitlive_ac7a: docs/operator.md does not mention loop-arm.sh"
fi

if grep -q "loop-arm.sh" "$SKILL_DIR/scripts/carbon-lane-install.sh" \
   && ! grep -qE 'enable --now[^|]*claude-build\.path' "$SKILL_DIR/scripts/carbon-lane-install.sh"; then
  ok "unitlive_ac7b: carbon-lane-install.sh routes through loop-arm.sh, no standalone enable --now claude-build.path"
else
  bad "unitlive_ac7b: carbon-lane-install.sh does not route through loop-arm.sh cleanly"
fi

exit $fail
