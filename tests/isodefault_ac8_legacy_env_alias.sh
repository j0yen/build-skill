#!/usr/bin/env bash
# isodefault_ac8_legacy_env_alias.sh — PRD-build-test-isolation-by-default AC8.
#
# Given a legacy caller exporting SELECT_GUARD_JOURNAL=/x/y.md, When it
# journals, Then the line lands in /x/y.md and one
# `journal  legacy-env  (name=SELECT_GUARD_JOURNAL)` notice is written
# there.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../scripts/lib/journal.sh"
[ -r "$LIB" ] || { echo "ac8: $LIB not found" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d /mnt/data/jsy/tmp/isodefault-ac8.XXXXXX)"
trap 'rm -rf "$T"' EXIT

unset BUILD_JOURNAL_ROOT BURST_LANE_JOURNAL GATE_WEDGE_JOURNAL SELECT_GUARD_JOURNAL \
      JOURNAL_DIR BUILD_JOURNAL_DIR TICK_JOURNAL_DIR CARGO_BUDGET_JOURNAL BUILD_TEST

# shellcheck source=../scripts/lib/journal.sh
source "$LIB"

export SELECT_GUARD_JOURNAL="$T/x/y.md"
journal_line "select  ac8-slug  same-target-admit  (target=ok)"
rc=$?

expect "rc is 0"                                       "[ $rc -eq 0 ]"
expect "the line lands in /x/y.md"                      "grep -q 'select  ac8-slug  same-target-admit' '$T/x/y.md'"
expect "one legacy-env notice was written there"        "grep -c 'journal  legacy-env  (name=SELECT_GUARD_JOURNAL)' '$T/x/y.md' | grep -qx 1"

# A second journal_line call in the SAME process must not repeat the
# notice (requirement 1: "a one-time ... notice").
journal_line "select  ac8-slug-2  same-target-admit  (target=ok2)"
expect "notice stays one-time within the same process" "[ \"\$(grep -c 'journal  legacy-env  (name=SELECT_GUARD_JOURNAL)' '$T/x/y.md')\" = 1 ]"

exit $fail
