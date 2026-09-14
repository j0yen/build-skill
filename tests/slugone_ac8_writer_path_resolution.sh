#!/usr/bin/env bash
# slugone_ac8_writer_path_resolution.sh — PRD-build-prd-slug-uniqueness
# AC8.
#
# Given an in-repo writer (mark-needs-classification.sh) updating an
# archived PRD by its queue path, When the write runs, Then it fails
# without creating a file and the error names the PRD's actual location.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MNC="$HERE/../scripts/mark-needs-classification.sh"
[ -x "$MNC" ] || { echo "ac8: $MNC not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac8.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/build-queue" "$ROOT/built-prds" "$ROOT/parked"
cat > "$ROOT/built-prds/PRD-shipped-already.md" <<'EOF'
# PRD — already shipped

- Status: built
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Reference by slug (the writer's own "path resolved by convention" case:
# no build-queue/ file exists for this slug anymore).
out="$(PRD_DIR="$ROOT" "$MNC" shipped-already "some reason" 2>&1)"
rc=$?
expect "exits non-zero" "[ $rc -ne 0 ]"
expect "error names the PRD's actual location (built-prds/)" \
  "printf '%s' \"\$out\" | grep -q '$ROOT/built-prds/PRD-shipped-already.md'"
expect "no file was created under build-queue/" \
  "[ ! -e '$ROOT/build-queue/PRD-shipped-already.md' ]"
expect "the built-prds/ copy is untouched" \
  "grep -q 'Status: built' '$ROOT/built-prds/PRD-shipped-already.md'"

# Also confirm a genuinely-unknown slug still gets the plain not-found
# message (no false "found elsewhere" claim).
out2="$(PRD_DIR="$ROOT" "$MNC" never-existed "some reason" 2>&1)"
rc2=$?
expect "unknown slug: exits non-zero" "[ $rc2 -ne 0 ]"
expect "unknown slug: plain not-found message, no location claimed" \
  "printf '%s' \"\$out2\" | grep -q 'no PRD file resolvable'"

exit $fail
