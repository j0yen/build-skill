#!/usr/bin/env bash
# vcrbps_ac2_freshest_wins.sh — PRD-build-verified-completed-realbox-
# perserver AC2.
#
# Given both a stale flat proof.json and a fresher, valid per-server
# proof, When check_real_box_evidence runs, Then it returns the freshest
# valid proof, never the stale flat file (and, symmetrically, a fresher
# flat file beats an older-but-still-valid per-server proof — freshness,
# not source, decides).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/vcrbps-ac-common.sh"
run_suite_and_expect_labels \
  "ok  AC2a both valid, per-server fresher -> per-server proof wins" \
  "ok  AC2b both valid, flat fresher -> flat proof wins (never shadowed by a source-order rule)" \
  "ok  AC2c stale flat never shadows a fresher, valid per-server proof"
