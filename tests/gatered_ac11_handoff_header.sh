#!/usr/bin/env bash
# gatered_ac11_handoff_header.sh — PRD-build-gate-red-alarm-invariant AC11: handoff-header.sh prints the summary line; SKILL.md's Handoff section names it
# Thin wrapper around scripts/gates-banner-selftest.sh's real assertions (same
# convention as tests/routepar_ac*.sh / tests/decisions_ac8_*.sh) — one
# real selftest run, per-AC labels pulled out for verified-completed.sh's
# --derive pairing (test_prefix: gatered).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(bash "$HERE/../scripts/gates-banner-selftest.sh" 2>&1)"; rc=$?
matched="$(printf '%s\n' "$out" | grep -E "AC11[^0-9]")"
printf '%s\n' "$matched"
if [ -z "$matched" ]; then
  echo "FAIL: no AC11 lines found in gates-banner-selftest.sh's output" >&2
  exit 1
fi
if printf '%s\n' "$matched" | grep -q "^FAIL"; then
  echo "FAIL: AC11 has a failing line in gates-banner-selftest.sh's output" >&2
  exit 1
fi
[ "$rc" -eq 0 ] || { echo "note: gates-banner-selftest.sh exited $rc overall (other ACs may have failed; AC11's own lines above are what this wrapper checks)" >&2; }
exit 0
