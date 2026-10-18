#!/usr/bin/env bash
# xrepo_ac6_selftest_and_key_parity.sh — PRD-build-prd-lint-cross-repo-ac AC6.
#
# Given prd-lint-selftest.sh and the key-parity section, When run at the
# landing commit, Then both new keys are known and every new id has a failing
# and a passing fixture (selftest total increases by >= 6, 0 FAIL).
# Baseline before this PRD: 85 checks.
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

SELFTEST="$HERE/../scripts/prd-lint-selftest.sh"
out="$(bash "$SELFTEST" 2>&1)"; rc=$?
expect "AC6: selftest exits 0 with no FAIL line" "[ $rc -eq 0 ] && ! grep -q '^FAIL' <<<\"\$out\""
total="$(sed -n 's/^SELFTEST PASSED (\([0-9]*\) checks)$/\1/p' <<<"$out")"
expect "AC6: selftest total ($total) >= 85 + 6" "[ -n \"$total\" ] && [ \"$total\" -ge 91 ]"
expect "AC6: key-parity passes" "grep -q '^ok: key-parity' <<<\"\$out\""
expect "AC6: both new keys are in the key-parity KNOWN_LINT_KEYS" \
  "grep -E '^KNOWN_LINT_KEYS=' \"\$SELFTEST\" | grep -q 'foreign_surface_ok foreign_surface_reasons'"
for id in ac-names-foreign-surface foreign-surface-reason-missing foreign-surface-ok-prose; do
  expect "AC6: $id has a failing fixture" "grep -q \"^ok: .*-> FAIL $id\" <<<\"\$out\""
  expect "AC6: $id has a passing fixture" "grep -q \"^ok: .*/pass.* -> no $id\|^ok: ac-names-foreign-surface/.*-pass -> OK\" <<<\"\$out\""
done

exit $fail
