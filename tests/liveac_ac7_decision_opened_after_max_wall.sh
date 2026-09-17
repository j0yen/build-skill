#!/usr/bin/env bash
# liveac_ac7_decision_opened_after_max_wall.sh — PRD-build-live-ac-no-defer AC7.
#
# Given a (Live AC unproven for LIVE_AC_MAX_WALL (fixture sets 60s), When the tick runs, Then exactly one decision is opened naming the PRD, the AC number, and the missing evidence form.
#
# Thin wrapper over the PRD's own suite (same shape as
# liveac_ac1_lint_refuses_deferred_live_ac.sh). It exists so
# verified-completed.sh --derive pairs AC7 against THIS PRD's own
# test_prefix (liveac) instead of falling back to a prefix-less match
# and colliding with another PRD's tests/<other>_ac7_*.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/live-ac-selftest.sh"

out="$(bash "$SUITE" 2>&1)"; rc=$?

fail=0
while IFS= read -r label; do
  [ -n "$label" ] || continue
  if grep -qF "$label" <<<"$out"; then
    echo "ok  $label"
  else
    echo "FAIL: expected label missing from live-ac-selftest.sh: $label" >&2
    echo "$out" | tail -20 >&2
    fail=1
  fi
done <<'LABELS'
PASS  AC7: after LIVE_AC_MAX_WALL, exactly one decision is opened
PASS  AC7: the decision names the PRD, AC1, and the missing evidence form
PASS  AC7: a second tick against the same still-missing evidence opens no second decision
LABELS

[ "$fail" -eq 0 ] || exit 1
[ "$rc" -eq 0 ] || { echo "FAIL: live-ac-selftest.sh exited $rc (other AC(s) regressed)" >&2; echo "$out" | tail -20 >&2; exit 1; }
exit 0
