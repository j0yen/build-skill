#!/usr/bin/env bash
# tests/gateage_ac2_banner_stale.sh — PRD-build-gate-red-render-age AC2.
#
# gates-banner.sh's local (RedBaron) leg reads state/gate-red.summary
# directly -- the simplest of its three summary_line sources to pin
# deterministically via GATE_RED_NOW (lib/gate-red-age.sh), so this test
# exercises that leg. Isolated under a disposable tempdir: BUILD_STATE_DIR
# and BUILD_JOURNAL_ROOT both point under $T, never the real
# ~/.claude/skills/build/state or ~/brain/journal/build.
#
#   written 20 minutes before "now" -> `STALE 20m` in the summary line,
#     plus the extra STALE explainer line.
#   written 2 minutes before "now"  -> `age 2m`, no STALE line.
#
# Run: bash tests/gateage_ac2_banner_stale.sh   (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
GB="$SKILL_DIR/scripts/gates-banner.sh"
[ -x "$GB" ] || { echo "selftest: $GB not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gateage-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label ($cond)" >&2; FAIL=$((FAIL+1)); fi
}

WRITE_TS="2026-01-01T00:00:00Z"
WRITE_EPOCH="$(date -u -d "$WRITE_TS" +%s)"

run_case() {  # $1 = state dir, $2 = now offset seconds
  local d="$1" now_epoch=$(( WRITE_EPOCH + $2 ))
  mkdir -p "$d/state" "$d/journal"
  printf '%s GATES(3h): green=2 red=1 blockers: x x1 oldest-red=%s red_slugs: a\n' \
    "$WRITE_TS" "$WRITE_TS" > "$d/state/gate-red.summary"
  BUILD_STATE_DIR="$d/state" BUILD_JOURNAL_ROOT="$d/journal" \
    GATES_BANNER_HOSTNAME=redbaron GATE_RED_NOW="$now_epoch" \
    "$GB" 2>/dev/null
}

# ============================================================================
# 20 minutes old -> STALE.
# ============================================================================
D="$T/stale"
out_stale="$(run_case "$D" 1200)"
expect "20m: first line carries STALE 20m" \
  "printf '%s\n' \"\$out_stale\" | sed -n '1p' | grep -q '\[STALE 20m\]'"
expect "20m: STALE explainer line present" \
  "printf '%s\n' \"\$out_stale\" | grep -q 'STALE gate-red state: written 2026-01-01T00:00:00Z, STALE 20m — do not report these counts as current'"

# ============================================================================
# 2 minutes old -> age note, no STALE.
# ============================================================================
D="$T/fresh"
out_fresh="$(run_case "$D" 120)"
expect "2m: first line carries age 2m" \
  "printf '%s\n' \"\$out_fresh\" | sed -n '1p' | grep -q '\[age 2m\]'"
expect "2m: no STALE line" \
  "! printf '%s\n' \"\$out_fresh\" | grep -q 'STALE gate-red state'"

echo "gateage_ac2_banner_stale: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
