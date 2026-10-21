#!/usr/bin/env bash
# xrepo_ac2_bare_noun_passes.sh — prd-lint ac-names-foreign-surface matches a
# surface token only in command position.
#
# Given fixture repos A (script `alpha`) and B (script `beta`) and a PRD with
# build_into A whose AC 2 says "a disposable `beta` tenant that self-offboards
# in a `finally`" (the shape of the 1035 PRD: a bare CLI name used as a noun),
# Then prd-lint raises NO ac-names-foreign-surface, and the explain text states
# the rule ("two or more tokens"). RED at 829a58e, GREEN after.
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

# Fixture repos: A (pyproject script alpha), B (script beta, module beta/digest.py).
mkdir -p "$d/A/alpha" "$d/B/beta"
printf '[project.scripts]\nalpha = "alpha.cli:main"\n' > "$d/A/pyproject.toml"
: > "$d/A/alpha/__init__.py"
printf '[project.scripts]\nbeta = "beta.cli:main"\n' > "$d/B/pyproject.toml"
: > "$d/B/beta/__init__.py"; : > "$d/B/beta/digest.py"
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

mkprd "$q/PRD-xr2-noun.md" 'Given a disposable `beta` tenant that self-offboards in a `finally`, When the run ends, Then the tenant is gone.'
out="$("$LINT" --format pass-fail "$q/PRD-xr2-noun.md" 2>&1)"; rc=$?
expect "AC2: bare noun beta -> no ac-names-foreign-surface" "! grep -q 'ac-names-foreign-surface' <<<\"\$out\""
expect "AC2: bare noun beta -> exit 0" "[ $rc -eq 0 ]"

ex="$("$LINT" --explain ac-names-foreign-surface 2>&1)"
expect "AC2: explain text says \"two or more tokens\"" "grep -q 'two or more tokens' <<<\"\$ex\""
expect "AC2: explain text names the bare-name false negative" "grep -q 'bare CLI name in backticks is treated as prose' <<<\"\$ex\""
expect "AC2: explain text names the adjective false positive" "grep -q 'used as an adjective' <<<\"\$ex\""

exit $fail
