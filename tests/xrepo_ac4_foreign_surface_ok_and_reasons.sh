#!/usr/bin/env bash
# xrepo_ac4_foreign_surface_ok_and_reasons.sh — PRD-build-prd-lint-cross-repo-ac AC4.
#
# Given `foreign_surface_ok: [2]` + `foreign_surface_reasons: {"2": "fixture
# CLI, not subject"}`, When linted, Then clean; Given the list without the
# reason map, Then FAIL foreign-surface-reason-missing; Given
# `foreign_surface_ok: see below`, Then FAIL foreign-surface-ok-prose.
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

AC='Given a digest, When `beta render` runs, Then it prints the table.'
mkprd "$q/PRD-xr4-ok.md" "$AC" '- foreign_surface_ok: [2]' '- foreign_surface_reasons: {"2": "fixture CLI, not subject"}'
out="$("$LINT" "$q/PRD-xr4-ok.md" 2>&1)"; rc=$?
expect "AC4: list + reason map -> clean" "[ $rc -eq 0 ] && [ \"\$out\" = OK ]"

mkprd "$q/PRD-xr4-noreason.md" "$AC" '- foreign_surface_ok: [2]'
out="$("$LINT" --format pass-fail "$q/PRD-xr4-noreason.md" 2>&1)"; rc=$?
expect "AC4: list without reasons -> FAIL foreign-surface-reason-missing" "[ $rc -eq 1 ] && grep -q 'foreign-surface-reason-missing' <<<\"\$out\""

mkprd "$q/PRD-xr4-prose.md" "$AC" '- foreign_surface_ok: see below'
out="$("$LINT" --format pass-fail "$q/PRD-xr4-prose.md" 2>&1)"; rc=$?
expect "AC4: prose value -> FAIL foreign-surface-ok-prose" "[ $rc -eq 1 ] && grep -q 'foreign-surface-ok-prose' <<<\"\$out\""

mkprd "$q/PRD-xr4-other.md" "$AC" '- foreign_surface_ok: [1]' '- foreign_surface_reasons: {"1": "unrelated"}'
out="$("$LINT" --format pass-fail "$q/PRD-xr4-other.md" 2>&1)"
expect "AC4: an exemption covers only its own AC" "grep -q 'ac-names-foreign-surface' <<<\"\$out\""

# scan-prds.sh emits both keys
mkdir -p "$d/scan/build-queue"; cp "$q/PRD-xr4-ok.md" "$d/scan/build-queue/"
got="$(PRD_DIR="$d/scan" BUILD_STATE_DIR="$d/scan/state" "$HERE/../scripts/scan-prds.sh" 2>/dev/null | python3 -c '
import json, sys
p = json.load(sys.stdin)[0]
print(p["foreign_surface_ok"], p["foreign_surface_reasons"])' 2>&1)"
expect "AC4: scan-prds.sh emits foreign_surface_ok + foreign_surface_reasons" "[ \"\$got\" = \"[2] {'2': 'fixture CLI, not subject'}\" ]"

exit $fail
