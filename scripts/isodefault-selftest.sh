#!/usr/bin/env bash
# scripts/isodefault-selftest.sh — the one entrypoint for
# PRD-build-test-isolation-by-default's own acceptance criteria: runs
# every tests/isodefault_ac*.sh in order and reports a single verdict,
# same convention as gatedebt-selftest.sh / gatephase-selftest.sh's own
# "one script per PRD, ac* case files underneath" shape.
#
# Deliberately does NOT run itself through scripts/run-selftests.sh — its
# own AC1/AC3/AC7 cases must touch (or, for AC1/AC8, deliberately NOT
# touch) the real production journal directly to prove the tripwire/lint
# against real evidence; wrapping it in the runner's own isolation would
# defeat exactly what it's proving. Each isodefault_ac*.sh file is
# independently responsible for leaving production exactly as it found it
# (see each file's own before/after assertions).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$HERE/../tests" && pwd)"

cases=(
  "$TESTS_DIR"/isodefault_ac1_*.sh
  "$TESTS_DIR"/isodefault_ac2_*.sh
  "$TESTS_DIR"/isodefault_ac3_*.sh
  "$TESTS_DIR"/isodefault_ac4_*.sh
  "$TESTS_DIR"/isodefault_ac5_*.sh
  "$TESTS_DIR"/isodefault_ac6_*.sh
  "$TESTS_DIR"/isodefault_ac7_*.sh
  "$TESTS_DIR"/isodefault_ac8_*.sh
  "$TESTS_DIR"/isodefault_ac9_*.sh
)

pass=0
fail=0
declare -a failed_names=()

for c in "${cases[@]}"; do
  [ -f "$c" ] || { echo "isodefault-selftest: MISSING case file: $c" >&2; fail=$((fail + 1)); continue; }
  name="$(basename "$c")"
  echo "== isodefault-selftest: $name =="
  if bash "$c"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
done

echo "----"
echo "isodefault-selftest: $pass passed, $fail failed (of ${#cases[@]})"
if [ "$fail" -gt 0 ]; then
  printf 'isodefault-selftest: failed: %s\n' "${failed_names[*]}" >&2
  exit 1
fi
exit 0
