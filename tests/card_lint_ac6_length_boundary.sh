#!/usr/bin/env bash
# card_lint_ac6_length_boundary.sh — PRD-fleet-intent-card-conformance P1.
#
# Given the fixture cards at 501 and 500 bytes (intake.rs's AC-description
# cap, checked via Rust's str::len() — byte length, not char count), when
# card-lint.sh runs against each, then it fails the 501-byte one (naming
# the field) and passes the 500-byte one, and the overall script exits 0.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/card-lint.sh"
FIXTURE_501="$HERE/fixtures/card-lint-fixture-501.json"
FIXTURE_500="$HERE/fixtures/card-lint-fixture-500.json"

[ -x "$LINT" ]        || { echo "ac6: $LINT not executable" >&2; exit 2; }
[ -r "$FIXTURE_501" ] || { echo "ac6: $FIXTURE_501 missing" >&2; exit 2; }
[ -r "$FIXTURE_500" ] || { echo "ac6: $FIXTURE_500 missing" >&2; exit 2; }

repo="$(mktemp -d /tmp/card-lint-ac6.XXXXXXXX)"
trap 'rm -rf "$repo"' EXIT

fail=0

out_501="$("$LINT" "$repo" --card "$FIXTURE_501" 2>&1)"
rc_501=$?
if [ "$rc_501" -eq 1 ]; then
  echo "ok  501-byte description failed card-lint (exit 1)"
else
  echo "FAIL 501-byte description: expected exit 1, got $rc_501" >&2
  echo "$out_501" >&2
  fail=1
fi
case "$out_501" in
  *description*) ;;
  *) echo "FAIL 501-byte failure output does not name the description field:" >&2; echo "$out_501" >&2; fail=1 ;;
esac

out_500="$("$LINT" "$repo" --card "$FIXTURE_500" 2>&1)"
rc_500=$?
if [ "$rc_500" -eq 0 ]; then
  echo "ok  500-byte description passed card-lint (exit 0)"
else
  echo "FAIL 500-byte description: expected exit 0, got $rc_500" >&2
  echo "$out_500" >&2
  fail=1
fi

exit $fail
