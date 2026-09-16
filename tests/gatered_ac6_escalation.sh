#!/usr/bin/env bash
# gatered_ac6_escalation.sh — PRD-build-gate-red-alarm-invariant AC6: 3 consecutive same-red-slug ticks escalate with ALARM gate-red-persistent
# Thin wrapper around scripts/gate-red-tick-selftest.sh's real assertions (same
# convention as tests/routepar_ac*.sh / tests/decisions_ac8_*.sh) — one
# real selftest run, per-AC labels pulled out for verified-completed.sh's
# --derive pairing (test_prefix: gatered).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/gate-red-tick-selftest.sh" 2>&1)"; rc=$?
matched="$(printf '%s\n' "$out" | grep -E "AC6[^0-9]")"
printf '%s\n' "$matched"
if [ -z "$matched" ]; then
  echo "FAIL: no AC6 lines found in gate-red-tick-selftest.sh's output" >&2
  exit 1
fi
if printf '%s\n' "$matched" | grep -q "^FAIL"; then
  echo "FAIL: AC6 has a failing line in gate-red-tick-selftest.sh's output" >&2
  exit 1
fi
[ "$rc" -eq 0 ] || { echo "note: gate-red-tick-selftest.sh exited $rc overall (other ACs may have failed; AC6's own lines above are what this wrapper checks)" >&2; }
exit 0
