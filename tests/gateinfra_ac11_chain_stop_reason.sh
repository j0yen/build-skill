#!/usr/bin/env bash
# tests/gateinfra_ac11_chain_stop_reason.sh — PRD-build-gate-infra-outcome
# AC11 (P1, test_prefix gateinfra). Given a PRD chain that ends on an
# incomplete gate (manifest last_error="gate-infra:<phase>:<note>",
# status=blocked, no work_tree/build_target complications), When
# chain-guard.sh's chain-stop line is written, Then its reason is
# `gate-incomplete`, not the generic `blockers`/`needs-user` every real
# red gate also uses — a fixture manifest + a real chain-guard.sh call,
# same technique this repo's other chain-guard coverage
# (tests/chained-tick_ac*.sh) uses.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$HERE/.." && pwd -P)"
CHAIN_GUARD="$SKILL_DIR/scripts/chain-guard.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac11.XXXXXX")"
trap '[ -n "${GATEINFRA_KEEP:-}" ] || rm -rf "$T"' EXIT

STATE="$T/state"
mkdir -p "$STATE"
CHAIN_GUARD_JOURNAL="$T/journal.md"

echo "=== case A: gate-infra exhaustion -> stop: gate-incomplete (not blockers/needs-user) ==="
cat > "$STATE/manifest.json" <<'EOF'
{
  "prds": {
    "gateinfra-ac11-slug": {
      "slug": "gateinfra-ac11-slug",
      "status": "blocked",
      "build_target": "shell",
      "last_error": "gate-infra:reviewer-agent:claude -p subagent invocation failed",
      "blockers": []
    }
  }
}
EOF
out_a="$(BUILD_STATE_DIR="$STATE" BUILD_MANIFEST="$STATE/manifest.json" CHAIN_GUARD_JOURNAL="$CHAIN_GUARD_JOURNAL" \
  "$CHAIN_GUARD" check gateinfra-ac11-slug --skip-select-guard --prd-dir "$T/prds" 2>&1)"
rc_a=$?
expect "case A: exits 1 (stop)" "[ $rc_a -eq 1 ]"
expect "case A: reason is gate-incomplete" "[[ \"\$out_a\" == *'stop: gateinfra-ac11-slug: gate-incomplete'* ]]"
expect "case A: never the generic blockers/needs-user reason" \
  "[[ \"\$out_a\" != *'stop: gateinfra-ac11-slug: blockers'* ]] && [[ \"\$out_a\" != *'stop: gateinfra-ac11-slug: needs-user'* ]]"

echo "=== case B: a REAL block (last_error unrelated) still stops as blockers, unchanged ==="
cat > "$STATE/manifest.json" <<'EOF'
{
  "prds": {
    "gateinfra-ac11-slugB": {
      "slug": "gateinfra-ac11-slugB",
      "status": "blocked",
      "build_target": "shell",
      "last_error": "gate-block:branch:flake-audit",
      "blockers": ["flake-audit"]
    }
  }
}
EOF
out_b="$(BUILD_STATE_DIR="$STATE" BUILD_MANIFEST="$STATE/manifest.json" CHAIN_GUARD_JOURNAL="$CHAIN_GUARD_JOURNAL" \
  "$CHAIN_GUARD" check gateinfra-ac11-slugB --skip-select-guard --prd-dir "$T/prds" 2>&1)"
rc_b=$?
expect "case B: exits 1 (stop)" "[ $rc_b -eq 1 ]"
expect "case B: reason is still the generic blockers (a real block, unchanged behavior)" \
  "[[ \"\$out_b\" == *'stop: gateinfra-ac11-slugB: blockers'* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac11: ALL PASS"
else
  echo "gateinfra_ac11: assertion(s) FAILED"
fi
exit "$fail"
