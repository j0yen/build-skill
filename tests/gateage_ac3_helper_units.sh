#!/usr/bin/env bash
# tests/gateage_ac3_helper_units.sh — PRD-build-gate-red-render-age AC3.
#
# Unit-level coverage of scripts/lib/gate-red-age.sh's four functions,
# independent of any renderer. Run: bash tests/gateage_ac3_helper_units.sh
# (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
LIB="$SKILL_DIR/scripts/lib/gate-red-age.sh"
[ -r "$LIB" ] || { echo "selftest: $LIB not found" >&2; exit 2; }
# shellcheck source=../scripts/lib/gate-red-age.sh
source "$LIB"

T="$(mktemp -d "${TMPDIR:-/tmp}/gateage-ac3.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label ($cond)" >&2; FAIL=$((FAIL+1)); fi
}

TS="2026-06-15T12:00:00Z"
EPOCH="$(date -u -d "$TS" +%s)"

# ============================================================================
# gate_red_written_ts -- summary ts parse.
# ============================================================================
printf '%s GATES(3h): green=1 red=0\n' "$TS" > "$T/s.summary"
expect "written_ts: summary line-1 field-1" \
  "[ \"\$(gate_red_written_ts "$T/s.summary")\" = '$TS' ]"

# ============================================================================
# gate_red_written_ts -- json .ts parse.
# ============================================================================
if command -v jq >/dev/null 2>&1; then
  printf '{"ts":"%s","red":0}\n' "$TS" > "$T/s.json"
  expect "written_ts: json .ts field" \
    "[ \"\$(gate_red_written_ts "$T/s.json")\" = '$TS' ]"
else
  echo "skip json .ts test: jq not on PATH"
fi

# ============================================================================
# gate_red_age_s -- mtime fallback when line 1 doesn't parse as a ts.
# ============================================================================
printf 'not a timestamp at all\n' > "$T/bad.summary"
touch -d "@$((EPOCH - 300))" "$T/bad.summary"
expect "age_s: mtime fallback (300s)" \
  "[ \"\$(gate_red_age_s "$T/bad.summary" "$EPOCH")\" = 300 ]"

# ============================================================================
# gate_red_age_s / gate_red_age_note -- missing file -> -1 / no-data.
# ============================================================================
expect "age_s: missing file -> -1" \
  "[ \"\$(gate_red_age_s "$T/does-not-exist" "$EPOCH")\" = -1 ]"
expect "age_note: missing file -> no-data" \
  "[ \"\$(gate_red_age_note "$T/does-not-exist" "$EPOCH")\" = 'no-data' ]"
expect "is_stale: missing file -> stale (exit 0)" \
  "gate_red_is_stale '$T/does-not-exist' '$EPOCH'"

# ============================================================================
# threshold boundary: 900s -> age, 901s -> STALE (default threshold).
# ============================================================================
expect "boundary 900s: age note" \
  "[ \"\$(gate_red_age_note "$T/s.summary" "$((EPOCH + 900))")\" = 'age 15m' ]"
expect "boundary 900s: not stale" \
  "! gate_red_is_stale '$T/s.summary' '$((EPOCH + 900))'"
expect "boundary 901s: STALE note" \
  "[ \"\$(gate_red_age_note "$T/s.summary" "$((EPOCH + 901))")\" = 'STALE 15m' ]"
expect "boundary 901s: is stale" \
  "gate_red_is_stale '$T/s.summary' '$((EPOCH + 901))'"

# ============================================================================
# GATE_RED_STALE_AFTER_S env override.
# ============================================================================
expect "threshold override: 120s at +121s is STALE under a 120s threshold" \
  "[ \"\$(GATE_RED_STALE_AFTER_S=120 gate_red_age_note "$T/s.summary" "$((EPOCH + 121))")\" = 'STALE 2m' ]"
expect "threshold override: 120s at +119s is age under a 120s threshold" \
  "[ \"\$(GATE_RED_STALE_AFTER_S=120 gate_red_age_note "$T/s.summary" "$((EPOCH + 119))")\" = 'age 1m' ]"

# ============================================================================
# GATE_RED_NOW env fallback (no explicit now_epoch arg).
# ============================================================================
expect "GATE_RED_NOW env: age_s honors it without an explicit arg" \
  "[ \"\$(GATE_RED_NOW=$((EPOCH + 60)) gate_red_age_s "$T/s.summary")\" = 60 ]"

echo "gateage_ac3_helper_units: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
