#!/usr/bin/env bash
# isodefault_ac5_lint_code_mode.sh — PRD-build-test-isolation-by-default AC5.
#
# Given the repo after conversion, When lint-journal-fixtures.sh --code
# runs, Then it reports 0 private journal_line definitions and 0 journal
# env defaults outside lib/journal.sh; Given a new script that defines
# journal_line(), Then it reports file:line and exits 1.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
LINT="$SKILL_DIR/scripts/lint-journal-fixtures.sh"
[ -x "$LINT" ] || { echo "ac5: $LINT not found or not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# ---- part 1: the real repo, after conversion, is clean -------------------
out="$("$LINT" --code)"; rc=$?
expect "clean repo: --code exits 0"                  "[ $rc -eq 0 ]"
expect "clean repo: reports 0 private journal_line"   "printf '%s' \"\$out\" | grep -q '0 private journal_line definitions'"
expect "clean repo: reports 0 journal-root defaults"  "printf '%s' \"\$out\" | grep -q '0 journal-root defaults outside lib/journal.sh'"

# ---- part 2: a planted new script defining journal_line() is caught ------
T="$(mktemp -d /mnt/data/jsy/tmp/isodefault-ac5.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
offender="$T/scripts/new-offender.sh"
# Built via printf, one piece per line, rather than a heredoc that
# reproduces the literal offending definition as its own source line here
# — this test script lives under tests/, which the real repo-wide --code
# scan also walks, and a heredoc copy would trip that scan against ITSELF.
{
  printf '#!/usr/bin/env bash\n'
  printf '%s() {\n' "journal_line"
  printf '  echo "$1" >> "$JOURNAL"\n'
  printf '}\n'
} > "$offender"

# Run the lint against a throwaway tree shaped like the repo (scripts/lib/
# present but empty) so this test never mutates the real repo to prove the
# negative case.
mkdir -p "$T/scripts/lib" "$T/tests"
touch "$T/scripts/lib/journal.sh"
planted_out="$(SKILL_DIR_OVERRIDE=1 bash -c '
  HERE_DIR="$1"; shift
  SKILL_DIR="$HERE_DIR"
  grep -rnE "^[[:space:]]*journal_line[[:space:]]*\\(\\)" "$SKILL_DIR/scripts" "$SKILL_DIR/tests" 2>/dev/null \
    | grep -v "/lib/journal\\.sh:"
' _ "$T")"
planted_rc=0
[ -n "$planted_out" ] || planted_rc=1

expect "planted offender: at least one match found"  "[ $planted_rc -eq 0 ]"
expect "planted offender: names file:line"           "printf '%s' \"\$planted_out\" | grep -qE 'new-offender\\.sh:[0-9]+'"

# ---- part 3: same check, driven through the real lint binary on a copy
# of the repo's scripts/lib/journal.sh plus the offender, confirming the
# tool itself (not a hand-rolled grep) reports file:line and exits 1.
cp "$SKILL_DIR/scripts/lint-journal-fixtures.sh" "$T/lint-copy.sh"
sed -i "s#SKILL_DIR=\"\$(cd \"\$HERE/\\.\\.\" && pwd)\"#SKILL_DIR=\"$T\"#" "$T/lint-copy.sh"
chmod +x "$T/lint-copy.sh"
lint_out="$("$T/lint-copy.sh" --code)"; lint_rc=$?

expect "real lint binary: exits 1 on the planted offender" "[ $lint_rc -eq 1 ]"
expect "real lint binary: reports file:line"                "printf '%s' \"\$lint_out\" | grep -qE 'new-offender\\.sh:[0-9]+'"

exit $fail
