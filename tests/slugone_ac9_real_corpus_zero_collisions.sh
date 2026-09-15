#!/usr/bin/env bash
# slugone_ac9_real_corpus_zero_collisions.sh — PRD-build-prd-slug-
# uniqueness AC9.
#
# Given the real corpus at build time, When the audit runs, Then it exits
# 0 and reports zero collisions (the 2026-09-13 build-post-ship-reality-
# check pair was resolved by renaming the queued PRD before this shipped).
#
# Skips cleanly (exit 0) when the real PRD workspace isn't present on this
# host, e.g. a lane other than the one holding the shared clone.
#
# Also skips cleanly (does not fail) when manifest-invariants.sh itself
# fail-opens on tick.lock contention (its own documented requirement-4
# behavior: `{"status":"lock-contended",...}`, no "alarms" key, exit 0) --
# a parallel tick genuinely holding tick.lock for the healing pass is not
# evidence of a slug collision one way or the other, so this AC must not
# conflate "could not check" with "checked and found none". Retries a few
# times first since the contention is normally transient.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INV="$HERE/../scripts/manifest-invariants.sh"
[ -x "$INV" ] || { echo "ac9: $INV not executable" >&2; exit 2; }

PRD_DIR_REAL="${PRD_DIR:-$HOME/Documents/PRDs}"
if [ ! -d "$PRD_DIR_REAL/build-queue" ]; then
  echo "ac9: skip -- no real PRD workspace at $PRD_DIR_REAL"
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
# Poll with a short per-attempt flock wait (default 60s would make 3
# attempts cost up to 3 minutes for what should be a fast fixture) --
# an orphaned/stuck tick.lock holder won't clear in 1s any more than in
# 60s, so a tight poll + our own sleep between attempts is equivalent
# but fast; a holder that's merely mid-tick still gets 3 * (1s + 4s)
# of real wall time to finish and release.
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
  echo "ac9: skip -- manifest-invariants.sh --report tick.lock-contended after $max_attempts attempts (fail-open per its own requirement 4; not evidence of a collision)"
  exit 0
fi

expect "manifest-invariants --report exits 0" "[ $rc -eq 0 ]"
expect "zero slug-collision alarms in the real corpus" \
  "printf '%s' \"\$out\" | python3 -c 'import json,sys
d=json.load(sys.stdin)
cols=[a for a in d[\"alarms\"] if a[\"class\"]==\"slug-collision\"]
sys.exit(0 if not cols else 1)'"

exit $fail
