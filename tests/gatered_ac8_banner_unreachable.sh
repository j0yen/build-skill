#!/usr/bin/env bash
# gatered_ac8_banner_unreachable.sh — PRD-build-gate-red-alarm-invariant AC8: unreachable RedBaron with no cache prints the unknown line and exits 0 under 6s
# Thin wrapper around scripts/gates-banner-selftest.sh's real assertions (same
# convention as tests/routepar_ac*.sh / tests/decisions_ac8_*.sh) — one
# real selftest run, per-AC labels pulled out for verified-completed.sh's
# --derive pairing (test_prefix: gatered).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/gates-banner-selftest.sh" 2>&1)"; rc=$?
matched="$(printf '%s\n' "$out" | grep -E "AC8[^0-9]")"
printf '%s\n' "$matched"
if [ -z "$matched" ]; then
  echo "FAIL: no AC8 lines found in gates-banner-selftest.sh's output" >&2
  exit 1
fi
if printf '%s\n' "$matched" | grep -q "^FAIL"; then
  echo "FAIL: AC8 has a failing line in gates-banner-selftest.sh's output" >&2
  exit 1
fi
[ "$rc" -eq 0 ] || { echo "note: gates-banner-selftest.sh exited $rc overall (other ACs may have failed; AC8's own lines above are what this wrapper checks)" >&2; }
exit 0
