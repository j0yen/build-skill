#!/usr/bin/env bash
# paritycad_ac2_session_mismatch_one_reproof.sh — PRD-build-burst-parity-
# cadence AC2.
#
# Given the same receipt and a new session, When `gate` runs, Then exactly
# one re-proof runs, journals `parity  reproof  (cause=session)`, and
# routing follows its result.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  paritycad AC2: initial parity exits 0 with a clean diff" \
  "ok  paritycad AC2: exactly one re-proof journaled with cause=session" \
  "ok  paritycad AC2: the re-proof actually re-ran the local test exactly once" \
  "ok  paritycad AC2: routing follows the re-proof's result (gate proceeds, exit 0)" \
  "ok  paritycad AC2: the re-proof rewrote the receipt with the real active session_id"
