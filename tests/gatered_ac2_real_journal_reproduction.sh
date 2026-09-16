#!/usr/bin/env bash
# gatered_ac2_real_journal_reproduction.sh — PRD-build-gate-red-alarm-invariant AC2: reproduces the real 2026-09-16 stopgap aggregate (red=5, five mcphost slugs, hermetic-build top family)
# Thin wrapper around scripts/gate-red-summary-selftest.sh's real assertions (same
# convention as tests/routepar_ac*.sh / tests/decisions_ac8_*.sh) — one
# real selftest run, per-AC labels pulled out for verified-completed.sh's
# --derive pairing (test_prefix: gatered).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/gate-red-summary-selftest.sh" 2>&1)"; rc=$?
matched="$(printf '%s\n' "$out" | grep -E "AC2[^0-9]")"
printf '%s\n' "$matched"
if [ -z "$matched" ]; then
  echo "FAIL: no AC2 lines found in gate-red-summary-selftest.sh's output" >&2
  exit 1
fi
if printf '%s\n' "$matched" | grep -q "^FAIL"; then
  echo "FAIL: AC2 has a failing line in gate-red-summary-selftest.sh's output" >&2
  exit 1
fi
[ "$rc" -eq 0 ] || { echo "note: gate-red-summary-selftest.sh exited $rc overall (other ACs may have failed; AC2's own lines above are what this wrapper checks)" >&2; }
exit 0
