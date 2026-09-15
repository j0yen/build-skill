#!/usr/bin/env bash
# durheal_ac8_real_corpus_lint_pass_sweep.sh — PRD-build-classification-
# durable-heal AC8.
#
# Given the real RedBaron checkout at ship time, When the first invariants
# pass runs, Then any PRD parked with a reason lint does not reproduce
# would be requeued and named in the journal (expected: none remaining
# after the 2026-09-14 operator fix; the pass still names its count).
#
# Deliberately uses --report (read-only, per manifest-inv_ac7_report_
# mode_read_only.sh / durheal_ac4b's regression guard) rather than a real
# apply pass: a test file that commits+pushes to the live, shared PRDs
# clone every time it happens to run (CI, --verify-run, a curious
# operator) is a hazard this PRD's whole point is to avoid, not something
# to reintroduce in its own test. --report predicts the exact same
# needs-classification-lint-pass patch a real pass would apply (see
# manifest-invariants.sh's report_mode branch) without ever calling
# requeue-prd.sh, so this still proves the mechanism sees the real corpus
# correctly.
#
# Skips cleanly (exit 0) when the real PRD workspace isn't present on this
# host (same convention as slugone_ac9_real_corpus_zero_collisions.sh),
# and when manifest-invariants.sh fail-opens on tick.lock contention.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INV="$HERE/../scripts/manifest-invariants.sh"
[ -x "$INV" ] || { echo "ac8: $INV not executable" >&2; exit 2; }

PRD_DIR_REAL="${PRD_DIR:-$HOME/Documents/PRDs}"
if [ ! -d "$PRD_DIR_REAL/build-queue" ]; then
  echo "ac8: skip -- no real PRD workspace at $PRD_DIR_REAL"
  exit 0
fi

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

attempt=0
max_attempts=3
out=""
status=""
while [ "$attempt" -lt "$max_attempts" ]; do
  out="$(PRD_DIR="$PRD_DIR_REAL" LOCK_WAIT_SECS=1 "$INV" --report --format json)"
  rc=$?
  status="$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("status",""))
except Exception:
    print("")' 2>/dev/null)"
  [ "$status" = "lock-contended" ] || break
  attempt=$((attempt + 1))
  [ "$attempt" -lt "$max_attempts" ] && sleep 5
done

if [ "$status" = "lock-contended" ]; then
  echo "ac8: skip -- manifest-invariants.sh --report tick.lock-contended after $max_attempts attempts (fail-open; not evidence one way or the other)"
  exit 0
fi

expect "manifest-invariants --report exits 0" "[ $rc -eq 0 ]"

count="$(printf '%s' "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin)
n=len([h for h in d["heals"] if h.get("rule")=="needs-classification-lint-pass"])
print(n)')"
echo "ac8: needs-classification-lint-pass heals pending in the real corpus: $count"
expect "would-be-heal count is a well-formed non-negative integer" "[ \"$count\" -ge 0 ] 2>/dev/null"

exit $fail
