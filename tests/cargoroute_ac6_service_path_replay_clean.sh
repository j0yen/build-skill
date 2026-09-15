#!/usr/bin/env bash
# cargoroute_ac6_service_path_replay_clean.sh —
# PRD-build-cargo-route-precedence AC6 (spec test f). Given the real
# systemd-unit-shaped service PATH (/home/jsy/.local/bin:/home/jsy/.cargo
# /bin:/home/jsy/.npm-global/bin:/usr/local/bin:/usr/bin:/bin — no shim
# dir anywhere on it) and BUILD_BURST_ENABLED=1, when extend-gate.sh runs,
# then its own rewritten PATH guard (not just route-check) resolves the
# very first stdout line to cargo-budget-bin/cargo — the exact 2026-09-15
# defect (166 route=local vs 49 route=burst that day) replayed end-to-end
# and shown fixed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/cargoroute-ac-common.sh"
run_suite_and_expect_labels \
  "ok  cargoroute AC6: replaying the real service PATH resolves cargo-budget-bin FIRST (guard fixed it, not just detected it)"
