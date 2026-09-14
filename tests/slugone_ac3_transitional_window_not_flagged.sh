#!/usr/bin/env bash
# slugone_ac3_transitional_window_not_flagged.sh — PRD-build-prd-slug-
# uniqueness AC3.
#
# Given a fixture corpus where a slug appears in build-queue/ and
# built-prds/ with identical title and Drafted: (archive-commit's in-flight
# state, briefly the same PRD in two places within one commit), When lint
# and scan run, Then no collision is reported.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
SCAN="$HERE/../scripts/scan-prds.sh"
[ -x "$LINT" ] && [ -x "$SCAN" ] || { echo "ac3: lint/scan not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac3.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/prds/build-queue" "$ROOT/prds/built-prds" "$ROOT/prds/parked" "$ROOT/prds/visions"
mkdir -p "$ROOT/state"
touch "$ROOT/prds/visions/x.md"

body() {
cat <<'EOF'
# PRD — in-flight archive move

- Status: queued
- build_target: shell
- Vision: visions/x.md
- Drafted: 2026-09-11

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
}
body > "$ROOT/prds/build-queue/PRD-in-flight.md"
body > "$ROOT/prds/built-prds/PRD-in-flight.md"

echo '{"prds":{}}' > "$ROOT/state/manifest.json"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

lint_out="$("$LINT" "$ROOT/prds/build-queue/PRD-in-flight.md" --format json)"
lint_rc=$?
expect "lint exits 0 (no fails) on identical in-flight copies" "[ $lint_rc -eq 0 ]"
expect "lint output has no slug-not-unique" "! printf '%s' \"\$lint_out\" | grep -q 'slug-not-unique'"

scan_out="$(PRD_DIR="$ROOT/prds" BUILD_STATE_DIR="$ROOT/state" BUILD_MANIFEST="$ROOT/state/manifest.json" \
            JOURNAL="$ROOT/journal.md" "$SCAN")"
expect "scan still emits the buildable entry (not suppressed)" \
  "printf '%s' \"\$scan_out\" | python3 -c 'import json,sys; d=json.load(sys.stdin); import sys as s; s.exit(0 if any(e[\"slug\"]==\"in-flight\" for e in d) else 1)'"
expect "no slug-collision journal line for this slug" \
  "[ ! -f '$ROOT/journal.md' ] || ! grep -q 'slug-collision (slug=in-flight' '$ROOT/journal.md'"

exit $fail
