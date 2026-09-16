#!/usr/bin/env bash
# gatered_ac9_banner_red_present.sh — PRD-build-gate-red-alarm-invariant AC9: a fresh cache with red=5 shows the summary first and RED GATES PRESENT
# Thin wrapper around scripts/gates-banner-selftest.sh's real assertions (same
# convention as tests/routepar_ac*.sh / tests/decisions_ac8_*.sh) — one
# real selftest run, per-AC labels pulled out for verified-completed.sh's
# --derive pairing (test_prefix: gatered).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/gates-banner-selftest.sh" 2>&1)"; rc=$?
matched="$(printf '%s\n' "$out" | grep -E "AC9[^0-9]")"
printf '%s\n' "$matched"
if [ -z "$matched" ]; then
  echo "FAIL: no AC9 lines found in gates-banner-selftest.sh's output" >&2
  exit 1
fi
if printf '%s\n' "$matched" | grep -q "^FAIL"; then
  echo "FAIL: AC9 has a failing line in gates-banner-selftest.sh's output" >&2
  exit 1
fi
[ "$rc" -eq 0 ] || { echo "note: gates-banner-selftest.sh exited $rc overall (other ACs may have failed; AC9's own lines above are what this wrapper checks)" >&2; }
exit 0
