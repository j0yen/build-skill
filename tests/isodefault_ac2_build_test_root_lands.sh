#!/usr/bin/env bash
# isodefault_ac2_build_test_root_lands.sh — PRD-build-test-isolation-by-default AC2.
#
# Given BUILD_TEST=1 and BUILD_TEST_ROOT set, When the same fixture-shaped
# text is journaled, Then it lands under $BUILD_TEST_ROOT/journal/<date>.md
# and rc is 0.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/lib/journal.sh"
ISO="$HERE/../scripts/lib/isolation.sh"
[ -r "$LIB" ] || { echo "ac2: $LIB not found" >&2; exit 2; }
[ -r "$ISO" ] || { echo "ac2: $ISO not found" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d /mnt/data/jsy/tmp/isodefault-ac2.XXXXXX)"
trap 'rm -rf "$T"' EXIT

unset BUILD_JOURNAL_ROOT BURST_LANE_JOURNAL GATE_WEDGE_JOURNAL SELECT_GUARD_JOURNAL \
      JOURNAL_DIR BUILD_JOURNAL_DIR TICK_JOURNAL_DIR CARGO_BUDGET_JOURNAL

# shellcheck source=../scripts/lib/journal.sh
source "$LIB"
# shellcheck source=../scripts/lib/isolation.sh
source "$ISO"

# "Given BUILD_TEST=1 and BUILD_TEST_ROOT set" — the real precondition
# run-selftests.sh establishes for every test: isolation_apply is what
# turns BUILD_TEST_ROOT into BUILD_JOURNAL_ROOT (journal_line itself only
# ever reads BUILD_JOURNAL_ROOT directly, per requirement 1).
export BUILD_TEST=1
export BUILD_TEST_ROOT="$T"
isolation_apply

text='select red-fixture same-target-admit (target=/tmp/does-not-matter-ac2)'
journal_line "$text"
rc=$?

target="$T/journal/$(date -u +%F).md"

expect "rc is 0"                                    "[ $rc -eq 0 ]"
expect "line lands under \$BUILD_TEST_ROOT/journal"  "[ -f \"$target\" ]"
expect "the exact text was appended"                 "grep -qF -- \"\$text\" \"$target\""

exit $fail
