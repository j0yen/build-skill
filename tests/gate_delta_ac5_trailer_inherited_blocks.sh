#!/usr/bin/env bash
# gate_delta_ac5_trailer_inherited_blocks.sh — PRD-build-gate-delta-baseline AC5.
#
# Given a delta-pass ship, when the archive trailer is written, then it
# contains inherited_blocks=[...] naming the baseline receipts still
# blocking. Reuses the existing PRD-fixture-trailer.md (4 ACs,
# deferred_acs:[1,3]) already exercised by tests/archive-trailer.sh —
# this test only adds coverage for the new --inherited-blocks flag, and
# separately proves a plain ship (no flag) never emits the block.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="$HERE/../scripts/archive-trailer.sh"
FIXTURE="$HERE/fixtures/PRD-fixture-trailer.md"

[ -x "$GEN" ] || { echo "ac5: $GEN not executable" >&2; exit 2; }
[ -r "$FIXTURE" ] || { echo "ac5: $FIXTURE missing" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out_delta="$("$GEN" "$FIXTURE" \
  --paired 2='tests/jsonsnap.rs::roundtrip' \
  --paired 4='tests/schema.rs::roundtrip' \
  --inherited-blocks 'ci-checks,reviewer-agent' 2>/dev/null)"
rc_delta=$?

expect "delta-pass ship: exit 0" "[ $rc_delta -eq 0 ]"
expect "delta-pass ship: trailer names both baseline receipts" \
  "grep -qx 'inherited_blocks=\[ci-checks, reviewer-agent\]' <<<\"\$out_delta\""

out_plain="$("$GEN" "$FIXTURE" \
  --paired 2='tests/jsonsnap.rs::roundtrip' \
  --paired 4='tests/schema.rs::roundtrip' 2>/dev/null)"
expect "plain pass ship: no inherited_blocks line at all" \
  "! grep -q '^inherited_blocks=' <<<\"\$out_plain\""

exit $fail
