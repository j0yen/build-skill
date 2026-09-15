#!/usr/bin/env bash
# costrate_ac4_type_survives_env_flip.sh — PRD-build-burst-cost-rate-by-type
# AC4.
#
# Given a session booted as ccx43, When BURST_SERVER_TYPE is later flipped
# to ccx53 before teardown, Then the session still prices at ccx43's
# 0.522 eur/h, never ccx53's 1.009 — the SESSION's recorded server_type
# wins over the current env.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  costrate AC4: idle-guard tears down the ccx43-booted box" \
  "ok  costrate AC4: the session still reads server_type=ccx43 at teardown time" \
  "ok  costrate AC4: it is NOT priced at ccx53's 1.009 despite the env flip"
