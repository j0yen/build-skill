#!/usr/bin/env bash
# tests/rvrcpt_ac10_gates_banner_passthrough.sh — PRD-build-reviewer-
# receipt-primary AC10 (P1, test_prefix rvrcpt): "Given the new family
# key, When gates-banner.sh renders the GATES line, Then the key appears
# unchanged and untruncated below the first reason."
#
# gates-banner.sh just echoes gate-red-summary.sh's own first summary
# line verbatim (cut -d' ' -f2- on the write-ts prefix, no further
# truncation) — this seeds state/gate-red.summary directly with a
# reason-qualified family key and confirms gates-banner.sh's own output
# carries it byte-for-byte.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/rvrcpt-ac10.XXXXXX")"
trap '[ -n "${RVRCPT_KEEP:-}" ] || rm -rf "$T"' EXIT

STATE_DIR="$T/state"
mkdir -p "$STATE_DIR"
QUALIFIED_KEY="reviewer-agent:must-ac-failing-at-head"
printf '%s GATES(3h): green=2 red=1 blockers: %s x2 oldest-red=2026-09-17T05:00:00Z red_slugs: fixture-slug\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$QUALIFIED_KEY" > "$STATE_DIR/gate-red.summary"

out="$(GATES_BANNER_HOSTNAME=redbaron BUILD_STATE_DIR="$STATE_DIR" \
  bash "$SKILL_DIR/scripts/gates-banner.sh" 2>&1)"

expect "AC10: gates-banner output carries the qualified family key unchanged" \
  "[[ '$out' == *\"blockers: ${QUALIFIED_KEY} x2\"* ]]"
expect "AC10: the key is never truncated back to bare 'reviewer-agent x'" \
  "[[ '$out' != *' reviewer-agent x2'* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "rvrcpt_ac10: ALL PASS"
else
  echo "rvrcpt_ac10: assertion(s) FAILED"
fi
exit "$fail"
