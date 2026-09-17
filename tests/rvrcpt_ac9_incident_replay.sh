#!/usr/bin/env bash
# tests/rvrcpt_ac9_incident_replay.sh — PRD-build-reviewer-receipt-primary
# AC9 (P1, test_prefix rvrcpt): "Given the 2026-09-17 review-output.raw.txt
# and reviewer-agent.json pair stored as a fixture, When replayed through
# the phase, Then decision=block with 3 reasons and the blocking text
# names all three."
#
# tests/fixtures/rvrcpt-20260917-incident/ stores the real 05:15:46Z
# incident's raw stdout (a background-agent notification, no JSON
# substring anywhere in it — the Problem statement's own quote) and the
# real receipt that was on disk at the same mtime (decision=block, 3
# reasons). The fake claude patches head_sha/reviewed_at onto the receipt
# fixture with THIS run's own live values, at the moment it runs — this
# PRD's whole point is that FRESHNESS (not a frozen timestamp) is what
# makes a receipt authoritative, so a literal replay has to look fresh to
# the phase the same way the original did at the time.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"
FIXTURE_DIR="$HERE/fixtures/rvrcpt-20260917-incident"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/rvrcpt-ac9.XXXXXX")"
trap '[ -n "${RVRCPT_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"

# The fake claude patches head_sha/reviewed_at onto this fixture with its
# own LIVE values at the moment it runs (after `prepare`, same as a real
# subagent writing its receipt mid-turn) — never pre-seeded before the
# gate starts, which would replay as a STALE leftover (AC3's shape), not
# a live verdict (AC9's).
export FAKE_REVIEWER_RECEIPT_FIXTURE="$FIXTURE_DIR/reviewer-agent.json"
export FAKE_REVIEWER_STDOUT_MODE=fixture
export FAKE_REVIEWER_STDOUT_FIXTURE="$FIXTURE_DIR/review-output.raw.txt"
out="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_REVIEWER_RECEIPT_FIXTURE FAKE_REVIEWER_STDOUT_MODE FAKE_REVIEWER_STDOUT_FIXTURE

expect "AC9: verdict is decision=block" \
  "[[ '$out' == *'reviewer-agent — decision=block'* ]]"
expect "AC9: blocking text names all 3 reasons" \
  "[[ '$out' == *'reasons=must-ac-failing-at-head,ac-test-bindings-vacuous-for-must-acs,outside-src-file-changed-without-amendment'* ]]"
expect "AC9: no 'did not return valid JSON' note (the real incident's own false alarm)" \
  "[[ '$out' != *'did not return valid JSON'* ]]"
expect "AC9: no 'no fresh receipt' infra note (the receipt WAS fresh)" \
  "[[ '$out' != *'no fresh receipt'* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "rvrcpt_ac9: ALL PASS"
else
  echo "rvrcpt_ac9: assertion(s) FAILED"
fi
exit "$fail"
