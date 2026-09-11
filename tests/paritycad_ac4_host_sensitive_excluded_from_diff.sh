#!/usr/bin/env bash
# paritycad_ac4_host_sensitive_excluded_from_diff.sh — PRD-build-burst-
# parity-cadence AC4.
#
# Given `.burst-lane.toml` excluding a suite, When parity finds it FAILED
# locally and ok on the box (or vice versa), Then the receipt lists it
# under host_sensitive with both results, diff stays empty, and `gate`
# routes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  paritycad AC4: parity exits 0" \
  "ok  paritycad AC4: diff stays empty (the only disagreement is excluded)" \
  "ok  paritycad AC4: box-parity.json lists the excluded suite under host_sensitive with both results" \
  "ok  paritycad AC4: gate routes despite the host-sensitive suite (not blocked by it)"
