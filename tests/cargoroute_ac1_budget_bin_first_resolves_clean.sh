#!/usr/bin/env bash
# cargoroute_ac1_budget_bin_first_resolves_clean.sh —
# PRD-build-cargo-route-precedence AC1 (spec test a). Given the PATH
# already carries cargo_route_path_prefix()'s own output
# (cargo-budget-bin then burst-lane-bin) and burst is configured, when
# burst-lane.sh route-check runs, then it reports state=clean, names
# cargo-budget-bin/cargo as resolved (the chain's outermost, always-first
# entry), and exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/cargoroute-ac-common.sh"
run_suite_and_expect_labels \
  "ok  cargoroute AC1: correct-prefix PATH resolves state=clean" \
  "ok  cargoroute AC1: resolved names cargo-budget-bin/cargo (outermost, always first)" \
  "ok  cargoroute AC1: intended=burst (session up)" \
  "ok  cargoroute AC1: route-check exits 0"
