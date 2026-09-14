#!/usr/bin/env bash
# slugone_ac1_lint_rejects_duplicate_slug.sh — PRD-build-prd-slug-uniqueness
# AC1.
#
# Given two fixture PRDs with the same slug in build-queue/ and parked/,
# When prd-lint.sh runs, Then it fails with slug-not-unique and names both
# paths, both titles, and both Drafted: dates.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
[ -x "$LINT" ] || { echo "ac1: $LINT not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac1.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/build-queue" "$ROOT/built-prds" "$ROOT/parked" "$ROOT/visions"
touch "$ROOT/visions/x.md"

cat > "$ROOT/build-queue/PRD-dup-slug.md" <<'EOF'
# PRD — the queue copy

- Status: queued
- build_target: shell
- Vision: visions/x.md
- Drafted: 2026-09-10

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF

cat > "$ROOT/parked/PRD-dup-slug.md" <<'EOF'
# PRD — a different, unrelated PRD

- Status: parked
- build_target: shell
- Vision: visions/x.md
- Drafted: 2026-09-01

## Acceptance criteria

1. P0 — Given x, When y, Then z.
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out_json="$("$LINT" "$ROOT/build-queue/PRD-dup-slug.md" --format json)"
rc=$?
expect "prd-lint exits non-zero on a corpus collision" "[ $rc -ne 0 ]"
expect "failure id is slug-not-unique" "printf '%s' \"\$out_json\" | grep -q 'slug-not-unique'"
expect "message names the build-queue path" "printf '%s' \"\$out_json\" | grep -q '$ROOT/build-queue/PRD-dup-slug.md'"
expect "message names the parked path" "printf '%s' \"\$out_json\" | grep -q '$ROOT/parked/PRD-dup-slug.md'"
expect "message names the queue copy's title" "printf '%s' \"\$out_json\" | grep -q 'the queue copy'"
expect "message names the parked copy's title" "printf '%s' \"\$out_json\" | grep -q 'a different, unrelated PRD'"
expect "message names both Drafted dates" "printf '%s' \"\$out_json\" | grep -q '2026-09-10' && printf '%s' \"\$out_json\" | grep -q '2026-09-01'"

exit $fail
