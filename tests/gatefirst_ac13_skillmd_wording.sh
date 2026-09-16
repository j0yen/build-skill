#!/usr/bin/env bash
# gatefirst_ac13_skillmd_wording.sh — PRD-build-gate-before-land AC13.
#
# Given SKILL.md after this PRD, When both former
# `extend-gate.sh <build_into> --head <landed sha>` call sites are read,
# Then each describes gate-on-branch -> land-if-unchanged -> cached main
# check and the land-then-gate wording is absent (as a live instruction —
# see fixtures/gatefirst-ac-common.sh's header for why a HISTORICAL
# mention naming the old order is not itself a failure here).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_skillmd_wording_check
