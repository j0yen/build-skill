#!/usr/bin/env bash
# blockscope_ac6_lint_names_the_line.sh — PRD-build-burst-selftest-block-
# scoped-summary AC6.
#
# Given a new block that hand-rolls `[ $fail -eq 0 ]` in its summary, When
# the regression lint runs, Then it fails and names the offending line.
#
# Runs the REAL lint computation lifted verbatim out of
# scripts/burst-lane-selftest.sh (never a hand-duplicated regex, which could
# drift from the shipped one and pass a pattern the real lint would miss)
# against a synthetic victim file, and confirms the shipped suite itself
# still comes back clean.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/../scripts/burst-lane-selftest.sh"
[ -f "$SUITE" ] || { echo "FAIL: $SUITE not found" >&2; exit 2; }

lint_line="$(grep '^blockscope_lint_hits=' "$SUITE")"
[ -n "$lint_line" ] || { echo "FAIL: no blockscope_lint_hits= line found in $SUITE" >&2; exit 2; }

run_lint_against() {  # $1 = file to scan as if it were the running script
  local target="$1" dir base
  dir="$(cd "$(dirname "$target")" && pwd)"
  base="$(basename "$target")"
  HERE="$dir" bash -c "$lint_line"$'\n'"printf '%s' \"\$blockscope_lint_hits\"" "$base"
}

fail=0

victim="$(mktemp)"
cat > "$victim" <<'EOF'
fail=0
expect() { :; }
expect "widget: every widget case above ran green" "[ $fail -eq 0 ]"
EOF
victim_hits="$(run_lint_against "$victim")"
rm -f "$victim"
if grep -qF 'widget: every widget case above ran green' <<<"$victim_hits"; then
  echo "ok  AC6: the lint fires on a hand-rolled block summary and names the line"
else
  echo "FAIL AC6: the lint did not catch the hand-rolled victim line (got: $victim_hits)" >&2
  fail=1
fi

real_hits="$(run_lint_against "$SUITE")"
if [ -z "$real_hits" ]; then
  echo "ok  AC6: the shipped suite itself has no hand-rolled block summary"
else
  echo "FAIL AC6: the shipped suite unexpectedly trips its own lint:"$'\n'"$real_hits" >&2
  fail=1
fi
exit $fail
