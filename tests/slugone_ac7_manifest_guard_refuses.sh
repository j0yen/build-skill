#!/usr/bin/env bash
# slugone_ac7_manifest_guard_refuses.sh — PRD-build-prd-slug-uniqueness
# AC7.
#
# Given a slug with two corpus files, When manifest-set.sh attempts a
# status change, Then it refuses, exits non-zero, and journals the
# refusal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MS="$HERE/../scripts/manifest-set.sh"
[ -x "$MS" ] || { echo "ac7: $MS not executable" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/slugone-ac7.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/prds/build-queue" "$ROOT/prds/built-prds" "$ROOT/prds/parked"
mkdir -p "$ROOT/state/intent"
cat > "$ROOT/prds/build-queue/PRD-collided.md" <<'EOF'
# PRD — queue copy

- Status: queued
EOF
cat > "$ROOT/prds/parked/PRD-collided.md" <<'EOF'
# PRD — a foreign PRD

- Status: parked
EOF
echo '{"prds":{}}' > "$ROOT/state/manifest.json"

export PRD_DIR="$ROOT/prds"
export BUILD_STATE_DIR="$ROOT/state"
export BUILD_MANIFEST="$ROOT/state/manifest.json"
export JOURNAL="$ROOT/journal.md"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

status_patch="$ROOT/status.patch.json"
printf '{"status":"shipped"}' > "$status_patch"
"$MS" collided "$status_patch"; rc=$?
expect "manifest-set refuses (non-zero exit)" "[ $rc -ne 0 ]"
expect "manifest is unchanged (no status written for collided)" \
  "! grep -q '\"status\": \"shipped\"' '$ROOT/state/manifest.json' 2>/dev/null"
expect "journal records the refusal" "grep -q 'slug-collision-refuse (slug=collided' '$ROOT/journal.md'"

# Non-status patches on the same colliding slug are NOT gated.
other_patch="$ROOT/other.patch.json"
printf '{"blockers":["x"]}' > "$other_patch"
"$MS" collided "$other_patch"; rc2=$?
expect "a non-status patch on the same slug still succeeds" "[ $rc2 -eq 0 ]"

exit $fail
