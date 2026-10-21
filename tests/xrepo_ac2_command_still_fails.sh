#!/usr/bin/env bash
# xrepo_ac2_command_still_fails.sh — prd-lint ac-names-foreign-surface still
# fails a foreign CLI in command position (regression guard: GREEN before and
# after the command-position change, unlike xrepo_ac2_bare_noun_passes.sh).
#
# Given fixture repos A (script `alpha`) and B (script `beta`, module
# `beta/digest.py`) and a PRD with build_into A, Then an AC 2 holding
# `beta chain run --only journey`, `beta --version` (two tokens, flags count),
# `"digest.py"` (quoted script name alone), `digest.py --dry` or `digest.py`
# fails ac-names-foreign-surface naming AC 2 and the owning repo B.
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

n=0
check_fails() {
  local label="$1" ac2="$2" tok="$3" f out rc
  n=$((n+1)); f="$q/PRD-xr2-cmd$n.md"
  mkprd "$f" "$ac2"
  out="$("$LINT" --format pass-fail "$f" 2>&1)"; rc=$?
  expect "$label: exit 1" "[ $rc -eq 1 ]"
  expect "$label: fails ac-names-foreign-surface" "grep -q 'ac-names-foreign-surface' <<<\"\$out\""
  expect "$label: names AC 2 and token $tok" "grep -q 'AC 2 names' <<<\"\$out\" && grep -q \"'$tok'\" <<<\"\$out\""
  expect "$label: names the owning repo B" "grep -qF \"surface of $d/B\" <<<\"\$out\""
}

check_fails "cmd+subcommand+flag" 'Given a digest, When `beta chain run --only journey` runs, Then it prints the table.' beta
check_fails "cmd+flag (two tokens)" 'Given a digest, When `beta --version` runs, Then it prints the version.' beta
check_fails "quoted script name alone" 'Given a digest, When `"digest.py"` runs, Then it prints the table.' digest
check_fails "script name + flag" 'Given a digest, When `digest.py --dry` runs, Then it prints the table.' digest
check_fails "bare script name" 'Given a digest, When `digest.py` runs, Then it prints the table.' digest

exit $fail
