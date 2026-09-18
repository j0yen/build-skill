#!/usr/bin/env bash
# landres_ac7_report_orders_by_frequency.sh —
# PRD-build-land-conflict-resolver AC7 (P0): "Given
# scripts/land-conflicts-report.sh and a ledger with several records,
# When it runs, Then it prints files ordered by conflict count with class
# and last resolution." AC5's own test already checks the report prints
# class+last_resolution for a two-record ledger; AC7's distinct claim is
# the FREQUENCY ORDERING itself, so this test builds a ledger where three
# distinct files have three different conflict counts (3, 2, 1) plus a
# changed class/resolution on a file's later record (to prove "last"
# resolution wins, not "first"), and asserts the report's line order and
# per-line fields directly — no git/rebase mechanics involved, this is a
# pure ledger-in / report-out check.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPORT="$HERE/../scripts/land-conflicts-report.sh"
[ -x "$REPORT" ] || { echo "FAIL: $REPORT not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LEDGER="$WORK/land-conflicts.jsonl"

fail=0

# hot.txt: 3 records (most conflicted) -- last one flips class/resolution
# so the report must report the LAST record's fields, not the first's.
for i in 1 2; do
  printf '{"ts":"2026-09-1%sT00:00:00Z","repo":"repoX","slug":"s%s","file":"hot.txt","class":"generated","resolution":"regen","wall_seconds":1}\n' "$i" "$i" >>"$LEDGER"
done
printf '{"ts":"2026-09-13T00:00:00Z","repo":"repoX","slug":"s3","file":"hot.txt","class":"append_only","resolution":"union","wall_seconds":2}\n' >>"$LEDGER"

# warm.txt: 2 records.
for i in 1 2; do
  printf '{"ts":"2026-09-1%sT00:00:00Z","repo":"repoX","slug":"w%s","file":"warm.txt","class":"append_only","resolution":"union","wall_seconds":1}\n' "$i" "$i" >>"$LEDGER"
done

# cold.txt: 1 record.
printf '{"ts":"2026-09-11T00:00:00Z","repo":"repoX","slug":"c1","file":"cold.txt","class":"source","resolution":"coder","wall_seconds":30}\n' >>"$LEDGER"

report_out="$("$REPORT" "$LEDGER")"
lines=()
while IFS= read -r l; do lines+=("$l"); done <<<"$report_out"

if [ "${#lines[@]}" -eq 3 ]; then
  echo "ok  AC7: one line per distinct file (3 lines for 3 files)"
else
  echo "FAIL: expected 3 report lines, got ${#lines[@]}:" >&2
  printf '%s\n' "${lines[@]}" >&2
  fail=1
fi

if [[ "${lines[0]:-}" == "3  hot.txt"*class=append_only*last_resolution=union* ]]; then
  echo "ok  AC7: hot.txt (3 conflicts) is first, reports its LAST record's class/resolution (append_only/union, not the first two generated/regen)"
else
  echo "FAIL: line 1 expected '3  hot.txt ... class=append_only last_resolution=union', got: ${lines[0]:-<missing>}" >&2
  fail=1
fi

if [[ "${lines[1]:-}" == "2  warm.txt"*class=append_only*last_resolution=union* ]]; then
  echo "ok  AC7: warm.txt (2 conflicts) is second"
else
  echo "FAIL: line 2 expected '2  warm.txt ...', got: ${lines[1]:-<missing>}" >&2
  fail=1
fi

if [[ "${lines[2]:-}" == "1  cold.txt"*class=source*last_resolution=coder* ]]; then
  echo "ok  AC7: cold.txt (1 conflict) is third/last, class=source last_resolution=coder"
else
  echo "FAIL: line 3 expected '1  cold.txt ... class=source last_resolution=coder', got: ${lines[2]:-<missing>}" >&2
  fail=1
fi

exit $fail
