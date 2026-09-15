#!/usr/bin/env bash
# boxslots_ac6_sub_cap_shares_formula.sh — PRD-build-burst-run-slots-from-box AC6.
#
# Given the same session, When `cmd_sub_cap --candidates 10` and
# `run_slot_cap()` are both evaluated, Then their per-box terms are equal
# (one function; the selftest greps that `sub_cap` contains no inline
# `nproc/4` arithmetic).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  boxslots AC6: sub-cap and run_slot_cap() agree on the per-box term from matching box readings" \
  "ok  boxslots AC6: cmd_sub_cap's own body has no inline nproc/N or avail_gb/N arithmetic"
