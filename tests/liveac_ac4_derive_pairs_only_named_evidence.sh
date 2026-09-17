#!/usr/bin/env bash
# liveac_ac4_derive_pairs_only_named_evidence.sh — PRD-build-live-ac-no-defer AC4.
#
# Given a (Live AC naming journal:<regex> and a fixture tests/ file whose name would pair with that AC number, When verified-completed.sh --derive runs, Then the AC is unpaired until a matching journal line exists, after which it pairs with the journal evidence.
#
# Thin wrapper over the PRD's own suite (same shape as
# liveac_ac1_lint_refuses_deferred_live_ac.sh). It exists so
# verified-completed.sh --derive pairs AC4 against THIS PRD's own
# test_prefix (liveac) instead of falling back to a prefix-less match
# and colliding with another PRD's tests/<other>_ac4_*.sh.
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
PASS  AC4: a fixture tests/ file never pairs a (Live AC (unproven before its own evidence exists)
PASS  AC4: the (Live AC pairs once its own named journal evidence exists
PASS  AC4: verified-completed.sh reports a deferred (Live AC as live-ac-deferred, not DEFERRED
LABELS

[ "$fail" -eq 0 ] || exit 1
[ "$rc" -eq 0 ] || { echo "FAIL: live-ac-selftest.sh exited $rc (other AC(s) regressed)" >&2; echo "$out" | tail -20 >&2; exit 1; }
exit 0
