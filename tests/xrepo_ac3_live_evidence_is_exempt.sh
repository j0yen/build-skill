#!/usr/bin/env bash
# xrepo_ac3_live_evidence_is_exempt.sh — PRD-build-prd-lint-cross-repo-ac AC3.
#
# Given an AC whose only foreign token is inside `(Live; evidence: `ssh orch
# 'beta render'`)`, When linted, Then clean (live probes run anything). The
# exemption is the (Live tail only: the same token BEFORE the tail still fails.
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

mkprd "$q/PRD-xr3-live.md" 'Given the deployed host, When the digest renders, Then it lists every row (Live; evidence: `ssh orch '"'"'beta render'"'"'` prints the table)'
out="$("$LINT" "$q/PRD-xr3-live.md" 2>&1)"; rc=$?
expect "AC3: foreign token only in (Live; evidence: ...) -> clean" "[ $rc -eq 0 ] && [ \"\$out\" = OK ]"

mkprd "$q/PRD-xr3-before.md" 'Given a digest, When `beta render` runs, Then it prints the table (Live; evidence: `ssh orch alpha` prints it)'
out="$("$LINT" --format pass-fail "$q/PRD-xr3-before.md" 2>&1)"; rc=$?
expect "AC3: foreign token BEFORE the (Live tail still fails" "[ $rc -eq 1 ] && grep -q 'ac-names-foreign-surface' <<<\"\$out\""

exit $fail
