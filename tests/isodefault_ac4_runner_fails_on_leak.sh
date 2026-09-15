#!/usr/bin/env bash
# isodefault_ac4_runner_fails_on_leak.sh — PRD-build-test-isolation-by-default AC4.
#
# Given a test script that appends one line to the real journal, When run
# via run-selftests.sh, Then the runner fails that test and prints the
# leaked line.
#
# The fixture script below deliberately writes to
# $BUILD_TEST_REAL_HOME/brain/... (the pre-override real $HOME
# run-selftests.sh's own isolation_apply exports) rather than $HOME
# itself — a bare `$HOME` write inside a runner-launched subprocess would
# land under the already-overridden temp HOME and prove nothing; this
# simulates the realistic leak class (a script whose journal path doesn't
# key off the overridden $HOME at all). This test injects exactly one
# known line into the REAL production journal to prove detection, then
# surgically removes that exact line afterward — it does not rely on
# run-selftests.sh to self-heal (Non-goals: journals are append-only).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/../scripts/run-selftests.sh"
[ -x "$RUNNER" ] || { echo "ac4: $RUNNER not found or not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

REAL_JOURNAL="$HOME/brain/journal/build/$(date -u +%F).md"
leak_marker="isodefault-ac4-deliberate-leak-$$-$(date +%s%N)"

T="$(mktemp -d /mnt/data/jsy/tmp/isodefault-ac4.XXXXXX)"
trap 'rm -rf "$T"' EXIT

fixture="$T/leaky-fixture-selftest.sh"
cat > "$fixture" <<EOF
#!/usr/bin/env bash
set -uo pipefail
target="\${BUILD_TEST_REAL_HOME:-\$HOME}/brain/journal/build/\$(date -u +%F).md"
mkdir -p "\$(dirname "\$target")"
echo "$leak_marker" >> "\$target"
exit 0
EOF
chmod +x "$fixture"

out="$("$RUNNER" "$fixture" 2>&1)"
rc=$?

expect "runner exits non-zero on a leak"        "[ $rc -ne 0 ]"
expect "runner output names it a LEAK"          "printf '%s' \"\$out\" | grep -q 'LEAK'"
expect "runner prints the leaked line"          "printf '%s' \"\$out\" | grep -qF -- '$leak_marker'"

# Cleanup: the fixture really did append to the real journal (that's the
# point) — surgically remove exactly that one known line so this test
# leaves production untouched, same bar AC7 holds the real suite to.
if [ -f "$REAL_JOURNAL" ] && grep -qxF -- "$leak_marker" "$REAL_JOURNAL"; then
  tmp_clean="$(mktemp "$T/clean.XXXXXX")"
  grep -vxF -- "$leak_marker" "$REAL_JOURNAL" > "$tmp_clean"
  cat "$tmp_clean" > "$REAL_JOURNAL"
fi
expect "cleanup removed the injected line" "! grep -qxF -- '$leak_marker' \"$REAL_JOURNAL\" 2>/dev/null"

exit $fail
