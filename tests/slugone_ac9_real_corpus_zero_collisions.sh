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

out="$(PRD_DIR="$PRD_DIR_REAL" "$INV" --report --format json)"
rc=$?
expect "manifest-invariants --report exits 0" "[ $rc -eq 0 ]"
expect "zero slug-collision alarms in the real corpus" \
  "printf '%s' \"\$out\" | python3 -c 'import json,sys
d=json.load(sys.stdin)
cols=[a for a in d[\"alarms\"] if a[\"class\"]==\"slug-collision\"]
sys.exit(0 if not cols else 1)'"

exit $fail
