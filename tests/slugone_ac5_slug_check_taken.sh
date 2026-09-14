#!/usr/bin/env bash
# slugone_ac5_slug_check_taken.sh — PRD-build-prd-slug-uniqueness AC5.
#
# Given a slug already present anywhere in the corpus, When
# prd-slug-check.sh runs, Then it exits 1, names the existing location, and
# proposes a non-colliding slug.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/../scripts/prd-slug-check.sh"
[ -x "$CHECK" ] || { echo "ac5: $CHECK not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac5.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/build-queue" "$ROOT/built-prds" "$ROOT/parked"
cat > "$ROOT/built-prds/PRD-taken.md" <<'EOF'
# PRD — already shipped

- Status: built
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$(PRD_DIR="$ROOT" "$CHECK" taken)"
rc=$?
expect "exits 1" "[ $rc -eq 1 ]"
expect "names the existing location" "printf '%s' \"\$out\" | grep -q '$ROOT/built-prds/PRD-taken.md'"
expect "proposes a free slug (taken-v2)" "printf '%s' \"\$out\" | grep -q 'taken-v2'"

# Now occupy -v2 as well and confirm the proposal skips to the next free one.
cat > "$ROOT/build-queue/PRD-taken-v2.md" <<'EOF'
# PRD — v2 also taken

- Status: queued
EOF
out2="$(PRD_DIR="$ROOT" "$CHECK" taken)"
expect "skips an already-taken suffix and proposes taken-v3" "printf '%s' \"\$out2\" | grep -q 'taken-v3'"
expect "does not propose the already-taken taken-v2" "! printf '%s' \"\$out2\" | grep -q 'proposed free slug: taken-v2'"

exit $fail
