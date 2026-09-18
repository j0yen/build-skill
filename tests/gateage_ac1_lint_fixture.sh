#!/usr/bin/env bash
# tests/gateage_ac1_lint_fixture.sh — PRD-build-gate-red-render-age AC1.
#
# Exercises tests/lint_gate_red_renderers_show_age.sh's `--root`/`--extra`
# machinery against a disposable fixture tree instead of this repo's own
# scripts/ (same isolation posture as tests/lint_basename_as_identity.sh's
# neighbours) so the lint's own logic is proven independent of whatever
# this repo's real files happen to look like today:
#   (i)   a fixture renderer referencing gate-red.summary, no helper
#         adoption, no marker -> 1 violation.
#   (ii)  the same file with the `# lint:gate-red-not-rendered` marker on
#         the reference line -> 0 violations.
#   (iii) a `--extra` file (outside the fixture's scripts/) carrying
#         `# lint:gate-red-age-shown` -> 0 violations.
#
# Run: bash tests/gateage_ac1_lint_fixture.sh   (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LINT="$HERE/lint_gate_red_renderers_show_age.sh"
[ -x "$LINT" ] || { echo "selftest: $LINT not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gateage-ac1.XXXXXX")"
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
cat > "$T/scripts/my-renderer.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUMMARY_FILE="$STATE_DIR/gate-red.summary"
echo "$(sed -n '1p' "$SUMMARY_FILE" | cut -d' ' -f2-)"
EOF
out_i="$("$LINT" --root "$T" 2>&1)"; rc_i=$?
expect "(i) exit 1" "[ $rc_i -eq 1 ]"
expect "(i) names the violating line" "printf '%s\n' \"\$out_i\" | grep -q 'my-renderer.sh:3'"
expect "(i) exactly 1 violation of 1 site" "printf '%s\n' \"\$out_i\" | grep -q '1 violation(s) of 1 site(s) scanned'"

# ============================================================================
# (ii) same file, marker on the reference line -> 0 violations.
# ============================================================================
cat > "$T/scripts/my-renderer.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SUMMARY_FILE="$STATE_DIR/gate-red.summary"  # lint:gate-red-not-rendered -- test fixture, machine-only
echo "$(sed -n '1p' "$SUMMARY_FILE" | cut -d' ' -f2-)"
EOF
out_ii="$("$LINT" --root "$T")"; rc_ii=$?
expect "(ii) exit 0" "[ $rc_ii -eq 0 ]"
expect "(ii) 0 violations" "printf '%s\n' \"\$out_ii\" | grep -q '1 site(s) scanned, 0 violations'"

# ============================================================================
# (iii) --extra file with the age-shown marker -> 0 violations.
# ============================================================================
rm -f "$T/scripts/my-renderer.sh"
mkdir -p "$T/scripts"
: > "$T/scripts/.keep"
mkdir -p "$T/outside"
cat > "$T/outside/statusline.sh" <<'EOF'
#!/usr/bin/env bash
SUMMARY_FILE="$HOME/.claude/skills/build/state/gate-red.summary"  # lint:gate-red-age-shown -- own age logic, out of repo
EOF
out_iii="$("$LINT" --root "$T" --extra "$T/outside/statusline.sh")"; rc_iii=$?
expect "(iii) exit 0" "[ $rc_iii -eq 0 ]"
expect "(iii) 0 violations" "printf '%s\n' \"\$out_iii\" | grep -q '1 site(s) scanned, 0 violations'"

echo "gateage_ac1_lint_fixture: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
