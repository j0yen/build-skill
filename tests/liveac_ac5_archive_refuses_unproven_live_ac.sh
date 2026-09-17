#!/usr/bin/env bash
# liveac_ac5_archive_refuses_unproven_live_ac.sh — PRD-build-live-ac-no-defer AC5.
#
# Given a built loop-tooling PRD with one (Live AC unproven, When the archive step runs, Then it refuses, journals live-ac-unproven:<N>, and leaves the file in build-queue.
#
# Thin wrapper over the PRD's own suite (same shape as
# liveac_ac1_lint_refuses_deferred_live_ac.sh). It exists so
# verified-completed.sh --derive pairs AC5 against THIS PRD's own
# test_prefix (liveac) instead of falling back to a prefix-less match
# and colliding with another PRD's tests/<other>_ac5_*.sh.
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
PASS  AC5: archive-live-ac-refusal.sh refuses (exit 1) while the (Live AC is unproven
PASS  AC5: archive-live-ac-refusal.sh prints live-ac-unproven:1 on refusal
PASS  AC5: the refusal is journaled with live-ac-unproven:1
PASS  AC5: archive-live-ac-refusal.sh goes silent (exit 0, no output) once the named evidence exists
LABELS

[ "$fail" -eq 0 ] || exit 1
[ "$rc" -eq 0 ] || { echo "FAIL: live-ac-selftest.sh exited $rc (other AC(s) regressed)" >&2; echo "$out" | tail -20 >&2; exit 1; }
exit 0
