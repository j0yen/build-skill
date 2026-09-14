#!/usr/bin/env bash
# slugone_ac6_slug_check_free.sh — PRD-build-prd-slug-uniqueness AC6.
#
# Given a slug absent from the corpus, When prd-slug-check.sh runs, Then it
# exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/../scripts/prd-slug-check.sh"
[ -x "$CHECK" ] || { echo "ac6: $CHECK not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac6.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/build-queue" "$ROOT/built-prds" "$ROOT/parked"
# A different slug occupies the corpus, but not the one being checked.
cat > "$ROOT/built-prds/PRD-unrelated.md" <<'EOF'
# PRD — unrelated

- Status: built
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$(PRD_DIR="$ROOT" "$CHECK" brand-new-slug)"
rc=$?
expect "exits 0" "[ $rc -eq 0 ]"
expect "no stdout on the free path" "[ -z \"\$out\" ]"

# Empty corpus entirely: still free.
ROOT2="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac6b.XXXXXX")"
mkdir -p "$ROOT2/build-queue" "$ROOT2/built-prds" "$ROOT2/parked"
PRD_DIR="$ROOT2" "$CHECK" anything >/dev/null 2>&1
expect "exits 0 against an entirely empty corpus" "[ $? -eq 0 ]"
rm -rf "$ROOT2"

exit $fail
