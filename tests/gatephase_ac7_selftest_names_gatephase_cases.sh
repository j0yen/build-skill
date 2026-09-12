#!/usr/bin/env bash
# gatephase_ac7_selftest_names_gatephase_cases.sh — PRD-build-gate-phase-
# timing AC7.
#
# Given the selftest fixture set, When the build selftest runs, Then the
# gatephase cases are named and green.
#
# This test does NOT invoke the real aggregator (scripts/gatephase-
# selftest.sh) against the real tests/ dir — since this very file lives
# under tests/gatephase_ac*.sh, the aggregator's own loop would reach it
# and re-invoke the aggregator again, recursing without bound (the exact
# 2026-09-11 gatedebt-selftest.sh postmortem, PRD-build-gate-debt-auto-prd
# AC7). Instead it points the aggregator at an isolated scratch fixture
# set via GATEPHASE_TESTS_DIR, so the real aggregator binary and its real
# pass/name-cases behavior are exercised without any self-reference. See
# scripts/gatephase-selftest.sh's own reentrancy guard for the
# belt-and-braces fix at the aggregator level.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GS="$HERE/../scripts/gatephase-selftest.sh"
[ -x "$GS" ] || { echo "ac7: $GS not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gatephase-ac7.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

cat > "$SCRATCH/gatephase_ac_fixture_one.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCRATCH/gatephase_ac_fixture_two.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCRATCH"/gatephase_ac_fixture_*.sh

# Unset the reentrancy sentinel before the first (legitimate,
# non-recursive) call: if THIS test is itself run as a case inside a real
# gatephase-selftest.sh invocation, that outer run already exported
# GATEPHASE_SELFTEST_RUNNING=1 into our environment.
unset GATEPHASE_SELFTEST_RUNNING
out="$(GATEPHASE_TESTS_DIR="$SCRATCH" "$GS" 2>&1)"; rc=$?
expect "gatephase-selftest.sh exits 0 on an all-passing fixture set" "[ $rc -eq 0 ]"
expect "names gatephase_ac_fixture_one case" "grep -q 'gatephase_ac_fixture_one' <<<\"\$out\""
expect "names gatephase_ac_fixture_two case" "grep -q 'gatephase_ac_fixture_two' <<<\"\$out\""
expect "reports case count" "grep -Eq '2 case\\(s\\)' <<<\"\$out\""

out2="$(GATEPHASE_SELFTEST_RUNNING=1 GATEPHASE_TESTS_DIR="$SCRATCH" "$GS" 2>&1)"; rc2=$?
expect "reentrant invocation refuses (exit 3), not silently loops" "[ $rc2 -eq 3 ]"
expect "reentrant invocation names the guard reason" "grep -q 'refusing reentrant invocation' <<<\"\$out2\""

exit $fail
