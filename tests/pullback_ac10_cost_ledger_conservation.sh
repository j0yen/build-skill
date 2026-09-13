#!/usr/bin/env bash
# pullback_ac10_cost_ledger_conservation.sh — PRD-build-burst-pull-back-
# restore AC10.
#
# Given a completed session including a teardown sweep, When the cost
# ledger is read, Then its slug rows sum exactly to the session total.
#
# Matches scripts/burst-lane-selftest.sh's cost-attribution "AC3" block
# (~line 795): alpha/beta/gamma runs stay dirty, the teardown sweep pulls
# all three and lands a 4th "teardown" slug row, and the four slug rows'
# eur sums exactly to the session's eur. HOST CAVEAT: same as AC8 — this
# depends on sweep_dirty_worktrees actually running, which its own money
# guard (burst-lane.sh ~line 4993) skips whenever claude-build.path is not
# active. Never started/stopped by this fixture. On carbon/ryzen7 the loop
# is intentionally inactive, so this AC cannot be verified here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/fixtures/pullback-ac-common.sh"
pullback_run_suite

if ! pullback_loop_active; then
  echo "FAIL pullback AC10: cannot verify on this host — claude-build.path is inactive (carbon/ryzen7 build-lane policy, 09-08: RedBaron-only), so the teardown sweep never runs and no 'teardown' slug row is produced; the cost-attribution AC3 case sees 3 slug rows instead of the expected 4. Expected to pass on RedBaron. Selftest evidence:" >&2
  grep -F "AC3: cost ledger gains 4 slug rows" <<<"$PULLBACK_OUT" >&2 || true
  exit 1
fi

if grep -qF "ok  AC3: cost ledger gains 4 slug rows (incl. teardown sweep) whose eur sums exactly to the session eur" <<<"$PULLBACK_OUT"; then
  echo "ok  pullback AC10: cost ledger's slug rows (incl. the teardown sweep row) sum exactly to the session total"
  exit 0
else
  echo "FAIL pullback AC10: cost ledger slug-row conservation check did not pass:"$'\n'"$PULLBACK_OUT" >&2
  exit 1
fi
