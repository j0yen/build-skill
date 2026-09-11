#!/usr/bin/env bash
# parityr_ac1_self_attribution_by_binary_name.sh — PRD-build-burst-parity-robust
# AC1.
#
# Given a fake box (and local) nextest run where a fast suite's PASS line
# is printed in a different position than the other side lists it in, When
# `burst-lane.sh parity <repo>` runs, Then attribution is by the binary name
# each line carries — never by position — so the one real diff is found and
# nothing else is misattributed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  parityr AC1: parity exits 0" \
  "ok  parityr AC1: both sides captured via nextest" \
  "ok  parityr AC1: exactly one true diff (parity::other), despite box/local listing suites in different order" \
  "ok  parityr AC1: fast/slow attributed ok/ok, other attributed FAILED/ok — never misattributed by line order"
