#!/usr/bin/env bash
# liveac_ac6_reality_check_flips_built_to_shipped.sh — PRD-build-live-ac-no-defer AC6.
#
# Given the same PRD after the fixture journal gains the matching line, When the reality check runs, Then the PRD becomes shipped, the archive trailer records the evidence path, and the file moves to built-prds.
#
# Thin wrapper over the PRD's own suite (same shape as
# liveac_ac1_lint_refuses_deferred_live_ac.sh). It exists so
# verified-completed.sh --derive pairs AC6 against THIS PRD's own
# test_prefix (liveac) instead of falling back to a prefix-less match
# and colliding with another PRD's tests/<other>_ac6_*.sh.
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
PASS  AC6: still unproven -- reality check declines to ship (PRD stays in build-queue)
PASS  AC6: reality check exits 0 once the fixture journal line appears
PASS  AC6: build-queue/PRD-fixture-ac6.md is gone (archived for real)
PASS  AC6: built-prds/PRD-fixture-ac6.md exists
PASS  AC6: the archived copy records the (Live AC's evidence path
PASS  AC6: MANIFEST.md's line for the slug flips to shipped
PASS  AC6: the pending-state file for the slug is cleaned up once shipped
LABELS

[ "$fail" -eq 0 ] || exit 1
[ "$rc" -eq 0 ] || { echo "FAIL: live-ac-selftest.sh exited $rc (other AC(s) regressed)" >&2; echo "$out" | tail -20 >&2; exit 1; }
exit 0
