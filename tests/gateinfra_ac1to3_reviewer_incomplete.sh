#!/usr/bin/env bash
# tests/gateinfra_ac1to3_reviewer_incomplete.sh — PRD-build-gate-infra-
# outcome AC1-AC3 (test_prefix gateinfra). Drives the REAL extend-gate.sh
# reviewer phase through the SAME fake toolchain reviewer-receipt-
# selftest.sh already uses (tests/fixtures/rvrcpt-fake/, tests/fixtures/
# rvrcpt-common.sh) — this PRD's R1/R2/R3 sit right next to that PRD's own
# code (run_reviewer, the call site) so reusing its fixture is the
# faithful way to exercise them, not a shortcut.
#
#   AC1 — stub claude exits 1 (FAKE_REVCLAUDE_RC=1, no receipt written):
#         receipts/reviewer-agent.json exists with decision="pass",
#         skip_reason starting "infra:reviewer-agent:"; extend-gate.sh's
#         own journal line reads outcome=incomplete with infra=reviewer-
#         agent; exit code is 9 (not 0, not 1).
#   AC2 — reviewer runs and blocks for real (decision=block): outcome is
#         block, the journal's blocker list still names reviewer-agent's
#         reason (PRD-build-reviewer-receipt-primary behavior preserved).
#   AC3 — a real block from an UNRELATED producer (rvrcpt-fake's own
#         FAKE_GATE_OTHER_BLOCK=1 — a receipt-level block the aggregator
#         itself reports, never routed through this script's own
#         note_block/blocking_notes shell tracking — the exact gap R3's
#         safety net exists for) alongside reviewer infra: outcome is
#         block, the blocker list is never empty (R3 — this is the "…
#         verdict=block … blocking=none" shape from the Grounding, and it
#         must be impossible even for a block this PRD's own R1/R6 scope
#         never instrumented), and infra=reviewer-agent appears on the
#         SAME line, never inside the blocker list.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/fixtures/rvrcpt-common.sh"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

fresh_case() {
  local name="$1"
  T="$(mktemp -d "${TMPDIR:-/tmp}/gateinfra-ac1to3-$name.XXXXXX")"
  [ -n "${GATEINFRA_KEEP:-}" ] || trap_list="$trap_list $T"
  REPO="$T/repo"
  rvrcpt_write_fixture_crate "$REPO"
  JOURNAL="$T/journal.md"
  : > "$JOURNAL"
}
trap_list=""
cleanup() { [ -n "${GATEINFRA_KEEP:-}" ] || rm -rf $trap_list; }
trap cleanup EXIT

echo "=== AC1: claude -p invocation fails -> skip receipt + incomplete, never block ==="
fresh_case ac1
export FAKE_REVCLAUDE_RC=1
export FAKE_GH_AUTH_RC=0   # ci-checks passes cleanly so AC1 isolates the reviewer phase alone
out_1="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_1=$?
unset FAKE_REVCLAUDE_RC FAKE_GH_AUTH_RC
receipt_1="$REPO/target/autobuilder/receipts/reviewer-agent.json"
expect "AC1: exit code is 9 (incomplete — not 0 pass, not 1 block)" "[ $rc_1 -eq 9 ]"
expect "AC1: receipt exists" "[ -f '$receipt_1' ]"
expect "AC1: receipt decision is pass (aggregator never blocks on it)" \
  "[ \"\$(jq -r '.decision' '$receipt_1')\" = pass ]"
expect "AC1: receipt skip_reason starts infra:reviewer-agent:" \
  "[[ \"\$(jq -r '.skip_reason' '$receipt_1')\" == infra:reviewer-agent:* ]]"
expect "AC1: receipt has head_sha and captured_at" \
  "[ -n \"\$(jq -r '.head_sha' '$receipt_1')\" ] && [ -n \"\$(jq -r '.captured_at' '$receipt_1')\" ]"
expect "AC1: journal line's outcome is incomplete" "grep -qE '  gate  .*  incomplete  \(' '$JOURNAL'"
expect "AC1: journal line names infra=reviewer-agent" "grep -q 'infra=reviewer-agent' '$JOURNAL'"
expect "AC1: no journal line reports outcome=block" "! grep -qE '  gate  .*  block  \(' '$JOURNAL'"
expect "AC1: stdout/stderr never claims decision=block" "[[ \"\$out_1\" != *'decision=block'* ]]"

echo "=== AC2: reviewer runs and blocks for real -> outcome=block, reason named ==="
fresh_case ac2
export FAKE_REVIEWER_RECEIPT_DECISION=block
export FAKE_REVIEWER_RECEIPT_REASONS="must-ac-failing-at-head"
export FAKE_GH_AUTH_RC=0
out_2="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_2=$?
unset FAKE_REVIEWER_RECEIPT_DECISION FAKE_REVIEWER_RECEIPT_REASONS FAKE_GH_AUTH_RC
expect "AC2: exit code is 1 (block, not 9)" "[ $rc_2 -eq 1 ]"
expect "AC2: journal line's outcome is block" "grep -qE '  gate  .*  block  \(' '$JOURNAL'"
expect "AC2: journal blocker list names reviewer-agent's reason" \
  "grep -q 'blocking=reviewer-agent@.*decision=block reasons=must-ac-failing-at-head' '$JOURNAL'"

echo "=== AC3: a real (unrelated) block + reviewer infra, mixed on one run ==="
fresh_case ac3
export FAKE_REVCLAUDE_RC=1        # reviewer infra
export FAKE_GATE_OTHER_BLOCK=1    # a real block on a receipt this script
                                   # never note_block'd — FAKE_GH_AUTH_RC
                                   # stays at rvrcpt_run_gate's own default
                                   # (0/authenticated) so ci-checks passes
                                   # cleanly and this is the ONLY real block.
out_3="$(rvrcpt_run_gate "$REPO" "$JOURNAL" 2>&1)"
rc_3=$?
unset FAKE_REVCLAUDE_RC FAKE_GATE_OTHER_BLOCK
expect "AC3: exit code is 1 (block — the real block wins over infra)" "[ $rc_3 -eq 1 ]"
expect "AC3: journal line's outcome is block" "grep -qE '  gate  .*  block  \(' '$JOURNAL'"
expect "AC3: blocker list is never empty (R3 — 'verdict=block … blocking=none' is impossible)" \
  "! grep -qE 'blocking=none' '$JOURNAL'"
expect "AC3: blocker list never names reviewer-agent (that is infra, not a block)" \
  "! grep -qE 'blocking=[^)]*reviewer-agent' '$JOURNAL'"
expect "AC3: infra=reviewer-agent appears on the same line, outside the blocker list" \
  "grep -q 'infra=reviewer-agent' '$JOURNAL'"
expect "AC3: reviewer-agent's own skip receipt was still written" \
  "[ -f '$REPO/target/autobuilder/receipts/reviewer-agent.json' ]"

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "gateinfra_ac1to3: ALL PASS"
else
  echo "gateinfra_ac1to3: assertion(s) FAILED"
fi
exit "$fail"
