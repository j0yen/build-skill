#!/usr/bin/env bash
# gatedebt_ac7_selftest_names_gatedebt_cases.sh — PRD-build-gate-debt-
# auto-prd AC7.
#
# Given the selftest fixture set, When gatedebt-selftest.sh runs, Then it
# exits 0 and names the gatedebt cases (by file basename) so a human or a
# tick reading the output can tell which acceptance criterion each case
# covers without opening every file under tests/.
#
# This test does NOT invoke the real aggregator against the real tests/
# dir — an earlier version did, and since this very file lives under
# tests/gatedebt_ac*.sh, the aggregator's own loop reached it and it
# re-invoked the aggregator again, recursing without bound (fork-bombed
# >60 processes on RedBaron, 2026-09-11). Instead it points the aggregator
# at an isolated scratch fixture set via GATEDEBT_TESTS_DIR, so the
# real aggregator binary and real pass/name-cases behavior are exercised
# without any self-reference. See scripts/gatedebt-selftest.sh's own
# reentrancy guard for the belt-and-braces fix at the aggregator level.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GS="$HERE/../scripts/gatedebt-selftest.sh"
[ -x "$GS" ] || { echo "ac7: $GS not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gatedebt-ac7.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

cat > "$SCRATCH/gatedebt_ac_fixture_one.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCRATCH/gatedebt_ac_fixture_two.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCRATCH"/gatedebt_ac_fixture_*.sh

# Unset the reentrancy sentinel before the first (legitimate, non-
# recursive) call: when THIS test is itself run as a case inside a real
# gatedebt-selftest.sh invocation, that outer run already exported
# GATEDEBT_SELFTEST_RUNNING=1 into our environment — inheriting it here
# would make even a call against an unrelated scratch dir look reentrant.
unset GATEDEBT_SELFTEST_RUNNING
out="$(GATEDEBT_TESTS_DIR="$SCRATCH" "$GS" 2>&1)"; rc=$?
expect "gatedebt-selftest.sh exits 0 on an all-passing fixture set" "[ $rc -eq 0 ]"
expect "names gatedebt_ac_fixture_one case" "grep -q 'gatedebt_ac_fixture_one' <<<\"\$out\""
expect "names gatedebt_ac_fixture_two case" "grep -q 'gatedebt_ac_fixture_two' <<<\"\$out\""
expect "reports case count" "grep -Eq '2 case\\(s\\)' <<<\"\$out\""

# And the guard itself: a reentrant call (this process already has
# GATEDEBT_SELFTEST_RUNNING set once we simulate it) must fail fast, not
# recurse.
out2="$(GATEDEBT_SELFTEST_RUNNING=1 GATEDEBT_TESTS_DIR="$SCRATCH" "$GS" 2>&1)"; rc2=$?
expect "reentrant invocation refuses (exit 3), not silently loops" "[ $rc2 -eq 3 ]"
expect "reentrant invocation names the guard reason" "grep -q 'refusing reentrant invocation' <<<\"\$out2\""

exit $fail
