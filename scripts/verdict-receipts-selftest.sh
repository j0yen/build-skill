#!/usr/bin/env bash
# verdict-receipts-selftest.sh — hermetic acceptance harness for
# verdict-receipts.sh (PRD-build-verdict-receipts). Builds throwaway
# journals/PRDs/receipts under a tempdir (never touches the real
# ~/brain/journal/build) and asserts AC1-AC8, including the two named
# regression fixtures (the 2026-09-05/06 bisect claim and the 20:44
# summa unreachable block).
#
# Run: bash scripts/verdict-receipts-selftest.sh   (exit 0 = all pass)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VR="$HERE/verdict-receipts.sh"
PASS=0; FAIL=0
ck() { if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/verdict-receipts-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export BUILD_RECEIPTS_DIR="$T/receipts"
mkdir -p "$BUILD_RECEIPTS_DIR"

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

# ---- AC2 (+ the 2026-09-05/06 no-bisect regression fixture): a journal
# line with "bisected" and no receipt is flagged, naming the missing
# receipt kind. -------------------------------------------------------
cat > "$T/j-ac2.md" <<'EOF'
2026-09-06T03:24:19Z  mcphost-harness-judge-calibration  archive-check  NOT-ARCHIVED  (pytest 8 failed/379 passed reproducible at HEAD 340a8ac, bisected regression in consume.py/llm.py)
EOF
out="$(bash "$VR" scan "$T/j-ac2.md")"; rc=$?
ck "AC2 exits nonzero on unreceipted bisected+reproducible"  "[ $rc -gt 0 ]"
ck "AC2 names the bisected line"                             "grep -q '\[bisected\]' <<<\"\$out\""
ck "AC2 names missing bisect-log receipt"                    "grep -qi 'bisect-log' <<<\"\$out\""
ck "AC2 also flags the bare reproducible claim"              "grep -q '\[reproducible\]' <<<\"\$out\""

# ---- AC3: the 2026-09-05 20:44 summa block replayed verbatim as a PRD
# Blocked: fixture — one unspaced probe, no cross-check -> flagged. -----
cat > "$T/PRD-ac3-summa.md" <<'EOF'
- Status: blocked
- Blocked: RedBaron unreachable (SSH timeout to 100.73.175.108)
EOF
out="$(bash "$VR" scan "$T/PRD-ac3-summa.md")"; rc=$?
ck "AC3 summa fixture exits nonzero"          "[ $rc -gt 0 ]"
ck "AC3 flags as unreachable"                 "grep -q '\[unreachable\]' <<<\"\$out\""
ck "AC3 names missing probe/crosscheck"       "grep -qi 'probe' <<<\"\$out\""

# ---- AC4: Blocked: SSH timeout with two probes >=60s apart plus a
# crosscheck -> passes. -------------------------------------------------
mk_receipt "2026-09-06-fleetx-probe.txt"      "ssh -o ConnectTimeout=5 100.73.175.108 true" 255 "2026-09-06T20:44:00Z" "ssh: connect to host 100.73.175.108 port 22: Connection timed out"
mk_receipt "2026-09-06-fleetx-probe-2.txt"    "ssh -o ConnectTimeout=5 100.73.175.108 true" 255 "2026-09-06T20:47:10Z" "ssh: connect to host 100.73.175.108 port 22: Connection timed out"
mk_receipt "2026-09-06-fleetx-crosscheck.txt" "ssh -o ConnectTimeout=5 carbon true"          0   "2026-09-06T20:45:00Z" "ok"
cat > "$T/PRD-ac4-fleetx.md" <<EOF
- Status: blocked
- Blocked: RedBaron unreachable (SSH timeout; receipt: $BUILD_RECEIPTS_DIR/2026-09-06-fleetx-probe.txt, receipt: $BUILD_RECEIPTS_DIR/2026-09-06-fleetx-probe-2.txt, receipt: $BUILD_RECEIPTS_DIR/2026-09-06-fleetx-crosscheck.txt)
EOF
out="$(bash "$VR" scan "$T/PRD-ac4-fleetx.md")"; rc=$?
ck "AC4 spaced probes + crosscheck passes"    "[ $rc -eq 0 ]"
ck "AC4 prints PASS"                          "grep -q '^PASS' <<<\"\$out\""

# ---- AC1: red run + green re-run recorded per protocol -> flaky-infra
# passes (both receipts referenced), not blocked. -----------------------
mk_receipt "2026-09-06-judge-rerun-red.txt"   "uv run pytest tests/consume -x" 1 "2026-09-06T03:24:00Z" "8 failed, 379 passed"
mk_receipt "2026-09-06-judge-rerun-green.txt" "uv run pytest tests/consume -x" 0 "2026-09-06T03:31:00Z" "0 failed, 387 passed"
cat > "$T/j-ac1.md" <<EOF
2026-09-06T03:32:00Z  mcphost-harness-judge-calibration  archive  flaky-infra  (receipt: $BUILD_RECEIPTS_DIR/2026-09-06-judge-rerun-red.txt, receipt: $BUILD_RECEIPTS_DIR/2026-09-06-judge-rerun-green.txt)
EOF
out="$(bash "$VR" scan "$T/j-ac1.md")"; rc=$?
ck "AC1 flaky-infra with both receipts passes"  "[ $rc -eq 0 ]"

# ---- AC7: a re-run that times out records kind hang and counts as the
# second record for reproducibility. -------------------------------------
out="$(bash "$VR" record probe hangslug --timeout 1 -- sleep 5)"; rc=$?
ck "AC7 record exits 0 even when timed out"   "[ $rc -eq 0 ]"
ck "AC7 timed-out record path names kind hang" "[[ \"\$out\" == *-hang.txt ]]"
ck "AC7 hang receipt file exists"              "[ -f \"\$out\" ]"
ck "AC7 hang receipt records exit 124"         "grep -q '^exit: 124\$' \"\$out\""
red2="$BUILD_RECEIPTS_DIR/2026-09-06-repro2-red.txt"
mk_receipt "2026-09-06-repro2-red.txt" "uv run pytest -x" 1 "2026-09-06T04:00:00Z" "1 failed"
cat > "$T/j-ac7.md" <<EOF
2026-09-06T04:05:00Z  repro2  archive-check  NOT-ARCHIVED  (reproducible; receipt: $red2, receipt: $out)
EOF
out2="$(bash "$VR" scan "$T/j-ac7.md")"; rc=$?
# hang receipt has no shared output-tail line with the red receipt, so
# the "same failure" check is expected to still fail here — AC7 only
# promises the hang record COUNTS as a second record, i.e. clears the
# ">=2 receipts, both nonzero" bar, not that mismatched output passes.
ck "AC7 hang receipt satisfies the >=2-records floor (not a count failure)" \
   '! grep -q "requires >=2 recorded runs" <<<"$out2"'

# ---- AC6: a receipt file, when read, contains command/started-at/exit/
# output-tail/hostname. --------------------------------------------------
rp="$(bash "$VR" record smoke ac6slug -- echo hi)"
ck "AC6 receipt has command"      "grep -q '^command:' \"\$rp\""
ck "AC6 receipt has started-at"   "grep -q '^started-at:' \"\$rp\""
ck "AC6 receipt has exit"         "grep -q '^exit: 0\$' \"\$rp\""
ck "AC6 receipt has hostname"     "grep -q '^hostname:' \"\$rp\""
ck "AC6 receipt has output-tail"  "grep -q '^output-tail:' \"\$rp\""
ck "AC6 receipt captured stdout"  "grep -q 'hi' \"\$rp\""

# ---- Edge case: receipts dir missing is never a crash — scan/postflight
# create it rather than erroring. -----------------------------------------
rm -rf "$T/no-receipts-dir"
export BUILD_RECEIPTS_DIR2="$T/no-receipts-dir"
BUILD_RECEIPTS_DIR="$T/no-receipts-dir" bash "$VR" scan "$T/j-ac1.md" >/dev/null 2>&1
ck "receipts-dir-missing: scan creates the dir instead of crashing" "[ -d \"$T/no-receipts-dir\" ]"

# ---- AC5: postflight appends a flag line to the SAME journal naming the
# unreceipted verdict, and never fails the caller. -----------------------
cp "$T/j-ac2.md" "$T/j-ac5.md"
before_lines="$(wc -l < "$T/j-ac5.md")"
bash "$VR" postflight "$T/j-ac5.md"; rc=$?
after_lines="$(wc -l < "$T/j-ac5.md")"
ck "AC5 postflight always exits 0"                 "[ $rc -eq 0 ]"
ck "AC5 postflight appends a flag line"            "[ $after_lines -gt $before_lines ]"
ck "AC5 flag line names postflight-flag"           "grep -q 'postflight-flag' \"$T/j-ac5.md\""
ck "AC5 flag line names the offending word"        "grep -q 'bisected' \"$T/j-ac5.md\""

# postflight on an already-clean journal appends nothing.
: > "$T/j-clean.md"
echo "2026-09-06T05:00:00Z  someslug  archive  shipped  (gate: pass=25 block=0)" > "$T/j-clean.md"
before_clean="$(wc -l < "$T/j-clean.md")"
bash "$VR" postflight "$T/j-clean.md" >/dev/null
after_clean="$(wc -l < "$T/j-clean.md")"
ck "AC5 postflight is a no-op on a clean journal" "[ $before_clean -eq $after_clean ]"

# ---- AC8: --summary equivalent (summary <date>) prints one table with a
# receipt-status column, mixing receipted/unreceipted/none-needed. -------
mkdir -p "$T/journalday"
cp "$T/j-ac1.md" "$T/journalday/tmp1"
cat "$T/j-ac2.md" >> "$T/journalday/tmp1"
cat "$T/j-clean.md" >> "$T/journalday/tmp1"
mv "$T/journalday/tmp1" "$T/journalday/2026-09-06.md"
out="$(BUILD_JOURNAL_DIR="$T/journalday" bash "$VR" summary 2026-09-06)"; rc=$?
ck "AC8 summary exits 0"                      "[ $rc -eq 0 ]"
ck "AC8 summary has a header row"             "grep -q 'RECEIPT-STATUS' <<<\"\$out\""
ck "AC8 summary flags the bad bisected line"  "grep -q 'missing-or-malformed' <<<\"\$out\""
ck "AC8 summary marks the flaky-infra line receipted"  "echo \"\$out\" | grep 'flaky-infra' | grep -q 'receipted'"
ck "AC8 summary marks the shipped line none-needed"    "echo \"\$out\" | grep 'shipped' | grep -q 'none-needed'"

# ---- Edge case: reserved words in PRD body prose (not a Blocked: value)
# are never scanned. ------------------------------------------------------
cat > "$T/PRD-ac-prose.md" <<'EOF'
- Status: queued
## Problem statement
We once had a bisected regression that turned out to be reproducible
only in prose. This body text should never trip the validator.
EOF
out="$(bash "$VR" scan "$T/PRD-ac-prose.md")"; rc=$?
ck "prose-not-scanned: PRD body prose is exempt" "[ $rc -eq 0 ]"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
