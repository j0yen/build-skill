#!/usr/bin/env bash
# tests/gateinfra_ac6_red_summary_field.sh — PRD-build-gate-infra-outcome
# AC6 (test_prefix gateinfra). Given a fixture journal containing two
# `incomplete` lines and one `block` line, gate-red-summary.sh reads
# `red=1 incomplete=2` with an `incomplete` family per phase, and
# gates-banner.sh prints the `incomplete=` field (it just echoes the
# summary line verbatim — no separate banner-side change was needed for
# this, so this test proves that end to end rather than assuming it).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac6.XXXXXX")"
trap '[ -n "${GATEINFRA_KEEP:-}" ] || rm -rf "$T"' EXIT

JOURNAL_ROOT="$T/journal"
mkdir -p "$JOURNAL_ROOT"
cat > "$JOURNAL_ROOT/2026-09-17.md" <<'EOF'
2026-09-17T10:00:00Z  gate-then-land  slugA  gate-block attempt=1 blockers=flake-audit — bad
2026-09-17T10:05:00Z  gate-then-land  slugB  gate-incomplete attempt=1 infra=reviewer-agent
2026-09-17T10:06:00Z  gate-then-land  slugC  gate-incomplete attempt=1 infra=reviewer-agent
EOF

STATE="$T/state"
mkdir -p "$STATE"
out="$(BUILD_JOURNAL_ROOT="$JOURNAL_ROOT" BUILD_STATE_DIR="$STATE" GATE_RED_NOW="2026-09-17T12:00:00Z" \
  "$SKILL_DIR/scripts/gate-red-summary.sh" --window-h 6)"

expect "AC6: summary reads red=1 incomplete=2" "[[ \"\$out\" == *'red=1 incomplete=2'* ]]"
expect "AC6: summary names the reviewer-agent incomplete family" "[[ \"\$out\" == *'incomplete_infra: reviewer-agent x2'* ]]"
expect "AC6: json twin carries incomplete:2" "[ \"\$(jq -r '.incomplete' \"$STATE/gate-red.json\")\" = 2 ]"
expect "AC6: json twin's incomplete_families names reviewer-agent:2" \
  "[ \"\$(jq -r '.incomplete_families[\"reviewer-agent\"]' \"$STATE/gate-red.json\")\" = 2 ]"
expect "AC6: red=1 still counts only the real block, not the incompletes" \
  "[ \"\$(jq -r '.red' \"$STATE/gate-red.json\")\" = 1 ]"

# gates-banner.sh just echoes summary_line verbatim — prove the field
# survives that path too (GATES_BANNER_HOSTNAME=redbaron takes the local
# read branch, same STATE_DIR).
banner_out="$(GATES_BANNER_HOSTNAME=redbaron BUILD_STATE_DIR="$STATE" "$SKILL_DIR/scripts/gates-banner.sh" 2>&1)"
expect "AC6: gates-banner.sh prints the incomplete= field" "[[ \"\$banner_out\" == *'incomplete=2'* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac6: ALL PASS"
else
  echo "gateinfra_ac6: assertion(s) FAILED"
fi
exit "$fail"
