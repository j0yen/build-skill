#!/usr/bin/env bash
# gate-wedge-rollup-selftest.sh — regression coverage for
# gate-wedge-rollup.sh (PRD-build-gate-wall-clock requirement 8 / AC9).
# Fixture-only: synthetic wedge-receipt.json files and a synthetic
# restarts.log, never the real state/gate-wedge or
# state/sccache-assert dirs (same discipline as gate-wedge-selftest.sh /
# sccache-assert-selftest.sh — validating a rollup must never read or
# perturb live production receipts).
#
# Cases:
#   1. two wedge receipts (unknown, sccache-client-orphans) + one restart
#      today -> wedges_total=2, both classifications counted, correctly
#      grouped, sccache_restarts=1 (matches the PRD's own AC9 scenario:
#      "a day with two wedges and one assert-restart").
#   2. a receipt/restart dated a DIFFERENT day is excluded from today's count.
#   3. --dry-run prints the line but never touches the journal file.
#   4. without --dry-run, exactly one line is appended to the journal file
#      and it matches stdout.
#   5. a quiet day (no receipts, no restart log) still emits a valid line:
#      wedges_total=0 wedges={} sccache_restarts=0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROLLUP="$HERE/gate-wedge-rollup.sh"
[ -x "$ROLLUP" ] || { echo "selftest: $ROLLUP not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-wedge-rollup-selftest.XXXXXX")"
trap '[ -n "${GATE_WEDGE_ROLLUP_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

TODAY="2026-09-10"
TODAY_COMPACT="20260910"
YESTERDAY="2026-09-09"
YESTERDAY_COMPACT="20260909"

# --- case 1+2: two receipts today (one per classification), one receipt
#     yesterday (must be excluded); one restart today, one restart
#     yesterday (must be excluded) --------------------------------------
state1="$T/wedge-state1"
mkdir -p "$state1"
cat > "$state1/${TODAY_COMPACT}T010000Z-stepA-wedge-receipt.json" <<EOF
{"step":"stepA","budget_s":1800,"elapsed_s":1900,"classification":"unknown"}
EOF
cat > "$state1/${TODAY_COMPACT}T020000Z-stepB-wedge-receipt.json" <<EOF
{"step":"stepB","budget_s":1800,"elapsed_s":1850,"classification":"sccache-client-orphans"}
EOF
cat > "$state1/${YESTERDAY_COMPACT}T230000Z-stepC-wedge-receipt.json" <<EOF
{"step":"stepC","budget_s":1800,"elapsed_s":1999,"classification":"unknown"}
EOF

restart_log1="$T/restarts1.log"
{
  echo "{\"ts\":\"${TODAY}T03:00:00Z\",\"unit\":\"sccache-server.service\",\"pid\":\"1234\",\"started_at\":\"${TODAY}T03:00:01Z\"}"
  echo "{\"ts\":\"${YESTERDAY}T22:00:00Z\",\"unit\":\"sccache-server.service\",\"pid\":\"999\",\"started_at\":\"${YESTERDAY}T22:00:01Z\"}"
} > "$restart_log1"

journal1="$T/journal1.md"
out1="$(GATE_WEDGE_STATE_DIR="$state1" SCCACHE_ASSERT_RESTART_LOG="$restart_log1" \
  GATE_WEDGE_ROLLUP_JOURNAL="$journal1" "$ROLLUP" --date "$TODAY")"
rc1=$?

expect "case1 exit 0"                    "[ $rc1 -eq 0 ]"
expect "case1 wedges_total=2 (not 3)"     "[[ \"$out1\" == *'wedges_total=2'* ]]"
# grep -F, not an eval'd [[ ]] substring test: $out1 contains literal
# double-quote characters (the JSON blob) that would otherwise terminate
# the cond string early once expect() eval's it.
expect "case1 unknown count=1"            "printf '%s' \"\$out1\" | grep -qF '\"unknown\":1'"
expect "case1 sccache-client-orphans=1"   "printf '%s' \"\$out1\" | grep -qF '\"sccache-client-orphans\":1'"
expect "case1 sccache_restarts=1 (not 2)" "[[ \"$out1\" == *'sccache_restarts=1'* ]]"

# --- case 4: non-dry-run appended exactly one matching line to journal --
expect "case4 journal file created"       "[ -f '$journal1' ]"
expect "case4 exactly one journal line"   "[ \$(wc -l < '$journal1') -eq 1 ]"
expect "case4 journal line contains the summary" "grep -qF \"\$out1\" '$journal1'"

# --- case 3: --dry-run prints but never writes ---------------------------
journal_dry="$T/journal-dry.md"
out_dry="$(GATE_WEDGE_STATE_DIR="$state1" SCCACHE_ASSERT_RESTART_LOG="$restart_log1" \
  GATE_WEDGE_ROLLUP_JOURNAL="$journal_dry" "$ROLLUP" --date "$TODAY" --dry-run)"
expect "case3 dry-run still prints the line" "[[ \"$out_dry\" == *'wedges_total=2'* ]]"
expect "case3 dry-run never creates journal" "[ ! -e '$journal_dry' ]"

# --- case 5: quiet day, no receipts dir, no restart log ------------------
empty_state="$T/empty-state"
missing_log="$T/no-such-restarts.log"
journal_quiet="$T/journal-quiet.md"
out_quiet="$(GATE_WEDGE_STATE_DIR="$empty_state" SCCACHE_ASSERT_RESTART_LOG="$missing_log" \
  GATE_WEDGE_ROLLUP_JOURNAL="$journal_quiet" "$ROLLUP" --date "$TODAY")"
rc_quiet=$?
expect "case5 exit 0 on a quiet day"       "[ $rc_quiet -eq 0 ]"
expect "case5 wedges_total=0"              "[[ \"$out_quiet\" == *'wedges_total=0'* ]]"
expect "case5 wedges={}"                   "[[ \"$out_quiet\" == *'wedges={}'* ]]"
expect "case5 sccache_restarts=0"          "[[ \"$out_quiet\" == *'sccache_restarts=0'* ]]"
expect "case5 still journals a line"       "[ -f '$journal_quiet' ]"

if [ "$fail" -eq 0 ]; then
  echo "gate-wedge-rollup-selftest: all cases passed"
else
  echo "gate-wedge-rollup-selftest: FAILURES ABOVE" >&2
fi
exit "$fail"
