#!/usr/bin/env bash
# gatefirst_ac10_cargo_attribution_routed_local0.sh —
# PRD-build-gate-before-land AC10.
#
# Given a branch gate routed to the box, When it completes, Then its
# journal line shows cargo=burst:<n>/local:0 and RedBaron's cargo-budget
# ledger has no entry for it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/gatefirst-ac-common.sh"
run_cargoroute10_and_expect_labels \
  "ok  AC10 setup: worktree of repo2 exists" \
  "ok  AC10: gate completed (not a hang/timeout)" \
  "ok  AC10: cargo_route.intended=burst (branch-scoped gate, same session)" \
  "ok  AC10: at least one cargo call was decided burst" \
  "ok  AC10: local:0 — a branch-scoped gate routed to the box books nothing local" \
  "ok  AC10: journal line exists and carries scope=branch slug=" \
  "ok  AC10: journal line's cargo= field reads burst:<n>/local:0" \
  "ok  AC10: RedBaron's (isolated) cargo-budget ledger gained NO new rows from this run"
