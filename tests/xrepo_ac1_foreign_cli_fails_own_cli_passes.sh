#!/usr/bin/env bash
# xrepo_ac1_foreign_cli_fails_own_cli_passes.sh — PRD-build-prd-lint-cross-repo-ac AC1.
#
# Given fixture repos A (pyproject script `alpha`, module `alpha/digest.py`)
# and B (script `beta`) and a corpus naming both as build_into, When a PRD with
# build_into A has AC 2 "When `beta render` runs, Then ...", Then prd-lint FAILS
# ac-names-foreign-surface naming AC 2, `beta`, and B; Given AC 2 says
# `alpha render` instead, Then clean.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
SURF="$HERE/../scripts/repo-surface.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }
[ -x "$SURF" ] || { echo "FAIL: $SURF not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
export PRD_LINT_CACHE="$d/cache"
mkdir -p "$d/corpus/build-queue" "$d/corpus/built-prds" "$d/corpus/parked" "$d/corpus/visions"
echo "plain vision." > "$d/corpus/visions/plain.md"
q="$d/corpus/build-queue"

# Fixture repos: A (pyproject script alpha, module alpha/digest.py), B (script beta).
mkdir -p "$d/A/alpha" "$d/B/beta"
printf '[project.scripts]\nalpha = "alpha.cli:main"\n' > "$d/A/pyproject.toml"
: > "$d/A/alpha/__init__.py"; : > "$d/A/alpha/digest.py"
printf '[project.scripts]\nbeta = "beta.cli:main"\n' > "$d/B/pyproject.toml"
: > "$d/B/beta/__init__.py"
# The corpus names both repos as build_into (that is the fleet map).
printf -- '- Status: built\n- build_target: python-cli\n- build_into: %s\n- Vision: visions/plain.md\n' "$d/B" > "$d/corpus/built-prds/PRD-corpus-b.md"

# mkprd <file> <AC 2 body> [extra frontmatter...]
mkprd() {
  local f="$1" ac2="$2"; shift 2
  { printf -- '- Status: queued\n- build_target: python-cli\n- build_into: %s\n- Vision: visions/plain.md\n- Grounding: failure-derived (fixture)\n' "$d/A"
    for l in "$@"; do printf -- '%s\n' "$l"; done
    printf '\n## Acceptance criteria\n\n1. P0 — Given a fixture, When `alpha run` is invoked, Then it exits 0.\n2. P0 — %s\n' "$ac2"
  } > "$f"
}

mkprd "$q/PRD-xr1-foreign.md" 'Given a digest, When `beta render` runs, Then it prints the table.'
out="$("$LINT" --format pass-fail "$q/PRD-xr1-foreign.md" 2>&1)"; rc=$?
expect "AC1: foreign token -> exit 1" "[ $rc -eq 1 ]"
expect "AC1: fails ac-names-foreign-surface" "grep -q 'ac-names-foreign-surface' <<<\"\$out\""
expect "AC1: names AC 2" "grep -q 'AC 2 names' <<<\"\$out\""
expect "AC1: names the token beta" "grep -q \"'beta'\" <<<\"\$out\""
expect "AC1: names the owning repo B" "grep -qF \"surface of $d/B\" <<<\"\$out\""
expect "AC1: does not blame AC 1 (alpha run is A's own)" "! grep -q 'AC 1 names' <<<\"\$out\""

mkprd "$q/PRD-xr1-own.md" 'Given a digest, When `alpha render` runs, Then it prints the table.'
out="$("$LINT" "$q/PRD-xr1-own.md" 2>&1)"; rc=$?
expect "AC1: own CLI -> clean (exit 0, OK)" "[ $rc -eq 0 ] && [ \"\$out\" = OK ]"

exit $fail
