#!/usr/bin/env bash
# paritycad_ac1_session_valid_routes_past_head_change.sh — PRD-build-burst-
# parity-cadence AC1.
#
# Given a valid receipt for session S at HEAD A, When `gate` runs at HEAD B
# in session S with an unchanged toolchain fingerprint, Then it routes
# without running parity (head_sha is never compared).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  paritycad AC1: initial parity exits 0 with a clean diff" \
  "ok  paritycad AC1: receipt carries session_id + toolchain_fp" \
  "ok  paritycad AC1: gate at a NEW head routes (invokes extend-gate.sh, not a parity fallback)" \
  "ok  paritycad AC1: gate never falls back on the receipt's stale head_sha" \
  "ok  paritycad AC1: no re-proof happened (session+toolchain both still match)"
