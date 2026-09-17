#!/usr/bin/env bash
# tests/rvrcpt_ac1to5_receipt_primary.sh — PRD-build-reviewer-receipt-
# primary, AC1-AC5 (test_prefix rvrcpt). Drives the REAL extend-gate.sh
# reviewer phase through the fake toolchain at tests/fixtures/rvrcpt-fake/
# against a disposable fixture crate (never mcphost, never any production
# repo), one fresh repo+journal per scenario so a "no receipt"/"stale
# receipt" case is never polluted by a previous scenario's writes.
#
#   AC1 (a) — prose stdout + fresh receipt (decision=block) -> the phase
#             note is "reviewer-agent — decision=block reasons=...", and
#             "did not return valid JSON" never appears.
#   AC2 (b) — no receipt, prose-only stdout -> "no fresh receipt (found
#             head=none reviewed_at=none)", infra, no block verdict.
#   AC3 (c) — a receipt from a previous gate's head, prose-only stdout ->
#             note names the stale head, infra.
#   AC4 (d) — stdout has the real object buried in prose with its OWN
#             '{'/'}' characters, no receipt file -> balanced decoding
#             still finds and finalizes it (the old greedy \{.*\} regex
#             would not).
#   AC5 (e) — fresh receipt says block, stdout JSON says pass -> verdict
#             is block (receipt wins), one journal mismatch line exists.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

fresh_case() {  # -> exports REPO/JOURNAL for one clean scenario
  local name="$1"
  T="$(mktemp -d "${TMPDIR:-/tmp}/rvrcpt-ac1to5-$name.XXXXXX")"
  [ -n "${RVRCPT_KEEP:-}" ] || trap_list="$trap_list $T"
  REPO="$T/repo"
  rvrcpt_write_fixture_crate "$REPO"
  JOURNAL="$T/journal.md"
  : > "$JOURNAL"
}
trap_list=""
cleanup() { [ -n "${RVRCPT_KEEP:-}" ] || rm -rf $trap_list; }
trap cleanup EXIT

echo "=== AC1 (a): prose stdout + fresh receipt(block) -> verdict names reasons ==="
fresh_case ac1
export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_RECEIPT_REASONS="must-ac-failing-at-head,ac-test-bindings-vacuous-for-must-acs"
export FAKE_REVIEWER_STDOUT_MODE=prose
out_a="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_REVIEWER_STDOUT_MODE
expect "AC1: phase note names decision=block with both reasons" \
  "[[ '$out_a' == *'reviewer-agent — decision=block reasons=must-ac-failing-at-head,ac-test-bindings-vacuous-for-must-acs'* ]]"
expect "AC1: no 'did not return valid JSON' note anywhere" \
  "[[ '$out_a' != *'did not return valid JSON'* ]]"
expect "AC1: receipt on disk still reads decision=block (finalize used the receipt itself)" \
  "[ \"\$(jq -r '.decision' '$REPO/target/autobuilder/receipts/reviewer-agent.json')\" = block ]"

echo "=== AC2 (b): no receipt at all, prose-only stdout -> no-fresh-receipt infra note ==="
fresh_case ac2
export FAKE_REVIEWER_WRITE_RECEIPT=0
export FAKE_REVIEWER_STDOUT_MODE=prose
out_b="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_REVIEWER_WRITE_RECEIPT FAKE_REVIEWER_STDOUT_MODE
expect "AC2: note reads 'no fresh receipt (found head=none reviewed_at=none)'" \
  "[[ '$out_b' == *'reviewer-agent — no fresh receipt (found head=none reviewed_at=none)'* ]]"
expect "AC2: no decision=block verdict text anywhere" \
  "[[ '$out_b' != *'decision=block'* ]]"
expect "AC2: no receipt was ever written" \
  "[ ! -f '$REPO/target/autobuilder/receipts/reviewer-agent.json' ]"

echo "=== AC3 (c): receipt from a previous gate's head, prose-only stdout -> names stale head ==="
fresh_case ac3
mkdir -p "$REPO/target/autobuilder/receipts"
stale_head="deadbeef00000000000000000000000000000000"
cat > "$REPO/target/autobuilder/receipts/reviewer-agent.json" <<EOF
{"schema":"autobuilder.reviewer_agent_receipt.v1","head_sha":"$stale_head","intent_card_sha":"fake","decision":"pass","block_reasons":[],"concern_reasons":[],"falsification":{"test_audit":"ok","panic_audit":"ok","unsafe_audit":"ok","public_api_audit":"ok","deps_audit":"ok","drift_audit":"ok","counter_attack":{"description":"n/a","test_skeleton":"n/a"}},"reviewed_at":"2020-01-01T00:00:00Z"}
EOF
export FAKE_REVIEWER_WRITE_RECEIPT=0
export FAKE_REVIEWER_STDOUT_MODE=prose
out_c="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_REVIEWER_WRITE_RECEIPT FAKE_REVIEWER_STDOUT_MODE
stale7="${stale_head:0:7}"
expect "AC3: note names the stale head ($stale7)" \
  "[[ '$out_c' == *\"found head=$stale7\"* ]]"
expect "AC3: no decision=block verdict text anywhere" \
  "[[ '$out_c' != *'decision=block'* ]]"

echo "=== AC4 (d): stdout object buried in prose with its own braces, no receipt file ==="
fresh_case ac4
export FAKE_REVIEWER_WRITE_RECEIPT=0
export FAKE_REVIEWER_STDOUT_MODE=prose_with_braces
export FAKE_REVIEWER_STDOUT_DECISION=pass
out_d="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_REVIEWER_WRITE_RECEIPT FAKE_REVIEWER_STDOUT_MODE FAKE_REVIEWER_STDOUT_DECISION
expect "AC4: no 'no fresh receipt' infra note (balanced decode found the object)" \
  "[[ '$out_d' != *'no fresh receipt'* ]]"
expect "AC4: finalize wrote the balanced-decoded object to disk (decision=pass)" \
  "[ \"\$(jq -r '.decision' '$REPO/target/autobuilder/receipts/reviewer-agent.json')\" = pass ]"

echo "=== AC5 (e): fresh receipt=block, stdout JSON=pass -> receipt wins + mismatch line ==="
fresh_case ac5
export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_STDOUT_MODE=json
export FAKE_REVIEWER_STDOUT_DECISION=pass
out_e="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_STDOUT_MODE FAKE_REVIEWER_STDOUT_DECISION
expect "AC5: verdict is block (receipt wins)" \
  "[[ '$out_e' == *'reviewer-agent — decision=block'* ]]"
expect "AC5: journal carries the mismatch line" \
  "grep -q 'reviewer-receipt-vs-stdout mismatch file=block stdout=pass' '$JOURNAL'"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "rvrcpt_ac1to5: ALL PASS"
else
  echo "rvrcpt_ac1to5: assertion(s) FAILED"
fi
exit "$fail"
