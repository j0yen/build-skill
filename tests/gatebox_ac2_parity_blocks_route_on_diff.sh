#!/usr/bin/env bash
# gatebox_ac2_parity_blocks_route_on_diff.sh — PRD-build-gate-on-casper AC2.
#
# Given a fake box whose test run differs from RedBaron's in two suites,
# When `burst-lane.sh parity <repo>` runs, Then `receipts/box-parity.json`
# lists exactly those two suites in `diff`, the journal has `parity  diff`,
# and a following `gate` call exits 3 with `fallback: parity-diff`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/burst-lane-ac-common.sh"
run_suite_and_expect_labels \
  "ok  gatebox AC2: parity reports diff=2" \
  "ok  gatebox AC2: journal has 'parity  diff'" \
  "ok  gatebox AC2: box-parity.json diff lists exactly the two differing suites (req 2)" \
  "ok  gatebox AC2: gate refuses to route while parity is diff (exit 3)" \
  "ok  gatebox AC2: gate prints fallback: parity-diff"
