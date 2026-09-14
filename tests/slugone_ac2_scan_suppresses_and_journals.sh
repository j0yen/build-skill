#!/usr/bin/env bash
# slugone_ac2_scan_suppresses_and_journals.sh — PRD-build-prd-slug-
# uniqueness AC2.
#
# Given the same corpus (a slug colliding across two directories), When
# scan-prds.sh runs, Then it journals `slug-collision (slug=... paths="...")`
# and emits no buildable entry for that slug.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/../scripts/scan-prds.sh"
[ -x "$SCAN" ] || { echo "ac2: $SCAN not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac2.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/prds/build-queue" "$ROOT/prds/built-prds" "$ROOT/prds/parked" "$ROOT/prds/visions"
mkdir -p "$ROOT/state"
touch "$ROOT/prds/visions/x.md"

cat > "$ROOT/prds/build-queue/PRD-dup-slug.md" <<'EOF'
# PRD — the queue copy

- Status: queued
- build_target: shell
- Vision: visions/x.md
- Drafted: 2026-09-10

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
cat > "$ROOT/prds/parked/PRD-dup-slug.md" <<'EOF'
# PRD — a different, unrelated PRD

- Status: parked
- build_target: shell
- Vision: visions/x.md
- Drafted: 2026-09-01

## Acceptance criteria

1. P0 — Given x, When y, Then z.
EOF
# An unrelated, non-colliding PRD stays buildable.
cat > "$ROOT/prds/build-queue/PRD-solo.md" <<'EOF'
# PRD — solo, no collision

- Status: queued
- build_target: shell
- Vision: visions/x.md
- Drafted: 2026-09-10

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF

echo '{"prds":{}}' > "$ROOT/state/manifest.json"

out="$(PRD_DIR="$ROOT/prds" BUILD_STATE_DIR="$ROOT/state" BUILD_MANIFEST="$ROOT/state/manifest.json" \
       JOURNAL="$ROOT/journal.md" "$SCAN")"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

expect "scan exits and produces JSON output" "printf '%s' \"\$out\" | python3 -c 'import json,sys; json.load(sys.stdin)'"
expect "no buildable entry for the colliding slug" \
  "! printf '%s' \"\$out\" | python3 -c 'import json,sys; d=json.load(sys.stdin); import sys as s; s.exit(0 if any(e[\"slug\"]==\"dup-slug\" for e in d) else 1)'"
expect "the unrelated non-colliding PRD is still emitted" \
  "printf '%s' \"\$out\" | python3 -c 'import json,sys; d=json.load(sys.stdin); import sys as s; s.exit(0 if any(e[\"slug\"]==\"solo\" for e in d) else 1)'"
expect "journal has a slug-collision line naming the slug" \
  "grep -q 'slug-collision (slug=dup-slug' '$ROOT/journal.md'"
expect "journal line names both paths" \
  "grep -q 'build-queue/PRD-dup-slug.md' '$ROOT/journal.md' && grep -q 'parked/PRD-dup-slug.md' '$ROOT/journal.md'"

exit $fail
