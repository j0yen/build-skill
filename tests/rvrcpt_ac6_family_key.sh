#!/usr/bin/env bash
# tests/rvrcpt_ac6_family_key.sh — PRD-build-reviewer-receipt-primary AC6
# (+R10, test_prefix rvrcpt): "Given a gate journal with a reviewer block
# whose receipt has block_reasons: [must-ac-failing-at-head, ...], When
# gate-red-summary.sh computes families, Then the family key is
# reviewer-agent:must-ac-failing-at-head and the GATES line shows it."
#
# Two-part check:
#   1. a real extend-gate.sh run (fake toolchain) with a fresh
#      decision=block receipt actually rewrites `autobuilder gate`'s own
#      "  ✗ reviewer-agent — ..." line to name the first block_reason, and
#      target/autobuilder/last-verdict.json's new_blocks/inherited_blocks
#      carries the qualified name — never touching an UNRELATED producer's
#      own blocking line (FAKE_GATE_OTHER_BLOCK=1).
#   2. gate-red-summary.sh, fed a synthetic gate-then-land journal line
#      with blockers=reviewer-agent:must-ac-failing-at-head, reports that
#      exact family key untruncated (the R10 half — the `:` used to fall
#      outside the family regex's char class and get cut off).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"
SUMMARY="$RVRCPT_REPO_ROOT/scripts/gate-red-summary.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/rvrcpt-ac6.XXXXXX")"
trap '[ -n "${RVRCPT_KEEP:-}" ] || rm -rf "$T"' EXIT

echo "=== part 1: extend-gate.sh's own gate_out + last-verdict.json name the reason ==="
REPO="$T/repo"
rvrcpt_write_fixture_crate "$REPO"
JOURNAL="$T/journal.md"
: > "$JOURNAL"
export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_RECEIPT_REASONS="must-ac-failing-at-head,outside-src-file-changed-without-amendment"
export FAKE_REVIEWER_STDOUT_MODE=json
export FAKE_GATE_OTHER_BLOCK=1
out="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_REVIEWER_STDOUT_MODE FAKE_GATE_OTHER_BLOCK

expect "part1: gate_out names the first reason on the reviewer-agent line" \
  "[[ '$out' == *'✗ reviewer-agent:must-ac-failing-at-head —'* ]]"
expect "part1: the unrelated producer's own block line is untouched" \
  "[[ '$out' == *'✗ some-other-producer — unrelated fixture block, never rewritten'* ]]"
expect "part1: unrelated producer's name never got a ':' suffix" \
  "[[ '$out' != *'some-other-producer:'* ]]"

verdict_file="$REPO/target/autobuilder/last-verdict.json"
expect "part1: last-verdict.json exists" "[ -f '$verdict_file' ]"
if [ -f "$verdict_file" ]; then
  new_blocks="$(jq -r '.new_blocks // [] | join(",")' "$verdict_file" 2>/dev/null)"
  expect "part1: new_blocks names the qualified reviewer-agent family" \
    "[[ ',$new_blocks,' == *',reviewer-agent:must-ac-failing-at-head,'* ]]"
fi

echo "=== part 2: gate-red-summary.sh reports the qualified family key untruncated ==="
D="$T/journal-dir"
mkdir -p "$D"
TODAY="$(date -u +%F)"
printf '%sT04:00:00Z  gate-then-land  fixture-slug  gate-block attempt=1 blockers=reviewer-agent:must-ac-failing-at-head\n' "$TODAY" > "$D/$TODAY.md"
summary_out="$(BUILD_JOURNAL_ROOT="$D" BUILD_STATE_DIR="$T/state" bash "$SUMMARY" --now "${TODAY}T04:30:00Z" --window-h 6 2>&1)"
expect "part2: summary line names the family key untruncated" \
  "[[ '$summary_out' == *'reviewer-agent:must-ac-failing-at-head x1'* ]]"
expect "part2: the family key is never truncated back to bare 'reviewer-agent x'" \
  "[[ '$summary_out' != *' reviewer-agent x1'* ]]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "rvrcpt_ac6: ALL PASS"
else
  echo "rvrcpt_ac6: assertion(s) FAILED"
fi
exit "$fail"
