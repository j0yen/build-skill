#!/usr/bin/env bash
# tests/tickout_ac14_lint_fixture.sh — PRD-buildloop-tick-outcome-liveness
# AC14.
#
# Exercises tests/lint_gate_red_renderers_show_age.sh's `--root` machinery
# against a disposable fixture tree (same isolation posture as
# tests/gateage_ac1_lint_fixture.sh, the analogous fixture for the
# gate-red.summary/.json sites this lint originally covered) to prove the
# tick-outcome.json extension independent of whatever this repo's real
# files happen to look like today:
#   (i)  a fixture renderer referencing tick-outcome.json, no helper
#        adoption, no marker -> 1 violation.
#   (ii) the same file after adopting the helper (sources
#        lib/gate-red-age.sh and calls gate_red_age_s) -> 0 violations.
#
# Run: bash tests/tickout_ac14_lint_fixture.sh   (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LINT="$HERE/lint_gate_red_renderers_show_age.sh"
[ -x "$LINT" ] || { echo "selftest: $LINT not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/tickout-ac14.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; PASS=$((PASS+1))
  else echo "FAIL $label ($cond)" >&2; FAIL=$((FAIL+1)); fi
}

# ============================================================================
# (i) no helper, no marker -> 1 violation.
# ============================================================================
mkdir -p "$T/scripts"
cat > "$T/scripts/loop-renderer.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
TICK_OUTCOME_FILE="$STATE_DIR/tick-outcome.json"
echo "LOOP: last_ok=$(jq -r '.last_ok_ts // empty' "$TICK_OUTCOME_FILE")"
EOF
out_i="$("$LINT" --root "$T" 2>&1)"; rc_i=$?
expect "(i) exit 1" "[ $rc_i -eq 1 ]"
expect "(i) names the violating line" "printf '%s\n' \"\$out_i\" | grep -q 'loop-renderer.sh:3'"
expect "(i) exactly 1 violation of 1 site" "printf '%s\n' \"\$out_i\" | grep -q '1 violation(s) of 1 site(s) scanned'"

# ============================================================================
# (ii) same file, adopts lib/gate-red-age.sh -> 0 violations.
# ============================================================================
mkdir -p "$T/scripts/lib"
cat > "$T/scripts/lib/gate-red-age.sh" <<'EOF'
gate_red_age_s() { echo 0; }
EOF
cat > "$T/scripts/loop-renderer.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/gate-red-age.sh"
TICK_OUTCOME_FILE="$STATE_DIR/tick-outcome.json"
age="$(gate_red_age_s "$TICK_OUTCOME_FILE")"
echo "LOOP: last_ok=${age}"
EOF
out_ii="$("$LINT" --root "$T")"; rc_ii=$?
expect "(ii) exit 0" "[ $rc_ii -eq 0 ]"
expect "(ii) 0 violations" "printf '%s\n' \"\$out_ii\" | grep -q '1 site(s) scanned, 0 violations'"

echo "tickout_ac14_lint_fixture: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
