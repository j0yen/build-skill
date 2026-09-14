#!/usr/bin/env bash
# slugone_ac4_differing_copies_flagged.sh — PRD-build-prd-slug-uniqueness
# AC4.
#
# Given a fixture corpus where those two copies (build-queue/ and
# built-prds/) differ in title or Drafted:, When lint and scan run, Then a
# collision is reported.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
SCAN="$HERE/../scripts/scan-prds.sh"
[ -x "$LINT" ] && [ -x "$SCAN" ] || { echo "ac4: lint/scan not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

run_case() {
  local case_label="$1" q_drafted="$2" b_drafted="$3" q_title="$4" b_title="$5"
  local ROOT; ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac4.XXXXXX")"
  mkdir -p "$ROOT/prds/build-queue" "$ROOT/prds/built-prds" "$ROOT/prds/parked" "$ROOT/prds/visions"
  mkdir -p "$ROOT/state"
  touch "$ROOT/prds/visions/x.md"

  cat > "$ROOT/prds/build-queue/PRD-differs.md" <<EOF
# PRD — $q_title

- Status: queued
- build_target: shell
- Vision: visions/x.md
- Drafted: $q_drafted

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF
  cat > "$ROOT/prds/built-prds/PRD-differs.md" <<EOF
# PRD — $b_title

- Status: built
- build_target: shell
- Vision: visions/x.md
- Drafted: $b_drafted

## Acceptance criteria

1. P0 — Given x, When y, Then z.
EOF
  echo '{"prds":{}}' > "$ROOT/state/manifest.json"

  local lint_out lint_rc
  lint_out="$("$LINT" "$ROOT/prds/build-queue/PRD-differs.md" --format json)"
  lint_rc=$?
  expect "$case_label: lint fails" "[ $lint_rc -ne 0 ]"
  expect "$case_label: lint names slug-not-unique" "printf '%s' \"\$lint_out\" | grep -q 'slug-not-unique'"

  local scan_out
  scan_out="$(PRD_DIR="$ROOT/prds" BUILD_STATE_DIR="$ROOT/state" BUILD_MANIFEST="$ROOT/state/manifest.json" \
              JOURNAL="$ROOT/journal.md" "$SCAN")"
  # scan-prds.sh still (by design) emits the built-prds/ copy of a slug --
  # only the build-queue/ (buildable) entry is suppressed on a collision.
  expect "$case_label: scan suppresses the build-queue buildable entry" \
    "! printf '%s' \"\$scan_out\" | python3 -c 'import json,sys
d=json.load(sys.stdin)
import sys as s
s.exit(0 if any(e[\"slug\"]==\"differs\" and \"/build-queue/\" in e[\"path\"] for e in d) else 1)'"
  expect "$case_label: journal names the collision" \
    "grep -q 'slug-collision (slug=differs' '$ROOT/journal.md'"

  rm -rf "$ROOT"
}

# Case A: titles differ, Drafted the same.
run_case "differing-title" "2026-09-11" "2026-09-11" "queue copy" "a different PRD entirely"
# Case B: Drafted differs, titles the same.
run_case "differing-drafted" "2026-09-11" "2026-08-01" "same title" "same title"

exit $fail
