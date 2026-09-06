#!/usr/bin/env bash
# verdict_receipts_ac8_summary_table.sh — PRD-build-verdict-receipts AC8.
#
# Given --summary (implemented as the `summary <date>` subcommand) for a
# date with mixed verdicts, when it runs, then one table lists each
# verdict with its receipt status.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/../scripts/verdict-receipts.sh"
[ -x "$VR" ] || { echo "ac8: $VR not executable" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/vr-ac8.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_RECEIPTS_DIR="$T/receipts"
mkdir -p "$BUILD_RECEIPTS_DIR"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

mk_receipt() { # <name> <command> <exit> <started-at> <tail...>
  local name="$1" cmd="$2" ex="$3" ts="$4"; shift 4
  {
    printf 'command: %s\n' "$cmd"
    printf 'started-at: %s\n' "$ts"
    printf 'exit: %s\n' "$ex"
    printf 'hostname: test-host\n'
    printf 'output-tail:\n'
    printf '%s\n' "$@"
  } > "$BUILD_RECEIPTS_DIR/$name"
}

mk_receipt "2026-09-06-judge-rerun-red.txt"   "uv run pytest tests/consume -x" 1 "2026-09-06T03:24:00Z" "8 failed, 379 passed"
mk_receipt "2026-09-06-judge-rerun-green.txt" "uv run pytest tests/consume -x" 0 "2026-09-06T03:31:00Z" "0 failed, 387 passed"

mkdir -p "$T/journalday"
cat > "$T/journalday/2026-09-06.md" <<EOF
2026-09-06T03:32:00Z  mcphost-harness-judge-calibration  archive  flaky-infra  (receipt: $BUILD_RECEIPTS_DIR/2026-09-06-judge-rerun-red.txt, receipt: $BUILD_RECEIPTS_DIR/2026-09-06-judge-rerun-green.txt)
2026-09-06T03:24:19Z  mcphost-harness-judge-calibration  archive-check  NOT-ARCHIVED  (pytest 8 failed/379 passed reproducible at HEAD 340a8ac, bisected regression in consume.py/llm.py)
2026-09-06T05:00:00Z  someslug  archive  shipped  (gate: pass=25 block=0)
EOF

out="$(BUILD_JOURNAL_DIR="$T/journalday" bash "$VR" summary 2026-09-06)"; rc=$?
expect "summary exits 0"                              "[ $rc -eq 0 ]"
expect "summary has a header row"                     "grep -q 'RECEIPT-STATUS' <<<\"\$out\""
expect "summary flags the bad bisected line"          "grep -q 'missing-or-malformed' <<<\"\$out\""
expect "summary marks the flaky-infra line receipted" "echo \"\$out\" | grep 'flaky-infra' | grep -q 'receipted'"
expect "summary marks the shipped line none-needed"   "echo \"\$out\" | grep 'shipped' | grep -q 'none-needed'"

exit $fail
