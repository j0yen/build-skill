#!/usr/bin/env bash
# xrepo_ac5_repo_surface_is_generated.sh — PRD-build-prd-lint-cross-repo-ac AC5.
#
# Given `scripts/repo-surface.sh <synthorg clone>`, When run, Then the output
# contains `synthorg` and `mtproof` and no token typed in the script; Given a
# path with no Cargo.toml/pyproject.toml/scripts, Then empty output and exit 0.
# Hermetic: a synthorg-shaped fixture; set XREPO_SYNTHORG to a real clone to
# assert the same on it.
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

mkdir -p "$d/syn/src/synthorg" "$d/empty/docs"
printf '[project.scripts]\nsynthorg = "synthorg.cli:main"\n' > "$d/syn/pyproject.toml"
: > "$d/syn/src/synthorg/__init__.py"; : > "$d/syn/src/synthorg/mtproof.py"
SYN="$d/syn"; [ -d "${XREPO_SYNTHORG:-}" ] && SYN="$XREPO_SYNTHORG"
out="$("$SURF" "$SYN")"; rc=$?
expect "AC5: exit 0" "[ $rc -eq 0 ]"
expect "AC5: output contains synthorg" "grep -qx synthorg <<<\"\$out\""
expect "AC5: output contains mtproof" "grep -qx mtproof <<<\"\$out\""
expect "AC5: no token typed in the script (neither name appears in it)" "! grep -qE 'synthorg|mtproof' \"\$SURF\""
out="$("$SURF" "$d/empty")"; rc=$?
expect "AC5: no Cargo.toml/pyproject.toml/scripts -> empty output, exit 0" "[ -z \"\$out\" ] && [ $rc -eq 0 ]"

exit $fail
