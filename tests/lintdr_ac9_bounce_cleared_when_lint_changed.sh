#!/usr/bin/env bash
# lintdr_ac9_bounce_cleared_when_lint_changed.sh —
# PRD-build-prd-lint-deferred-reasons-key AC9.
#
# Given a bounce record whose diagnosis no longer reproduces at an
# unchanged frontmatter hash, When classification-self-heal.sh bounce-check
# runs, Then it clears the record and journals `bounce-cleared
# lint-changed`. Reproduces the real PRD-mcphost-tenant-tables shape: a
# PRD bounced under prd-lint.sh's PRE-fix rule (git HEAD, straight from
# this repo's own history -- not a hand-reconstructed string), then
# re-checked once the SHIPPED (fixed) prd-lint.sh is on LINT_SH.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CSH="$HERE/../scripts/classification-self-heal.sh"
LINT_NEW="$HERE/../scripts/prd-lint.sh"
[ -x "$CSH" ] || { echo "FAIL: $CSH not executable" >&2; exit 2; }
[ -x "$LINT_NEW" ] || { echo "FAIL: $LINT_NEW not executable" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/prds/build-queue" "$T/prds/visions" "$T/state"
echo "plain vision" > "$T/prds/visions/plain.md"
FIX="$T/prds/build-queue/PRD-lintdr-ac9.md"
cat > "$FIX" <<'EOF'
# PRD: lintdr-ac9

- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- deferred_ac_reasons: {"10": "reason ten", "11": "reason eleven"}

## Acceptance criteria

1. P0 - Given a, When b, Then c.
EOF
printf '{"prds":{},"built_at":"2020-01-01T00:00:00Z"}\n' > "$T/state/manifest.json"

# The real pre-fix prd-lint.sh, straight from this repo's own git history
# (the commit this dispatch started from) -- never a hand-reconstructed
# string, which risks silently testing a strawman instead of the real
# defect.
LINT_OLD="$T/prd-lint-old.sh"
git -C "$HERE/.." show HEAD:scripts/prd-lint.sh > "$LINT_OLD" 2>/dev/null || {
  echo "ac9: skip -- can't read HEAD:scripts/prd-lint.sh (not a git checkout, or first commit)"
  exit 0
}
chmod +x "$LINT_OLD"

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Sanity: the OLD lint genuinely fails this fixture the way tenant-tables
# was really parked (never trust a synthetic setup without checking it
# reproduces the real symptom first).
"$LINT_OLD" "$FIX" >/dev/null 2>&1
expect "ac9 setup: OLD prd-lint.sh really fails this fixture" "[ $? -ne 0 ]"

# Step 1: bounce with the OLD lint's verdict (the historical park).
LINT_SH="$LINT_OLD" BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" JOURNAL="$T/journal.md" \
  "$CSH" bounce-check "$FIX" deferred-acs-missing-justification \
  'deferred_acs is a non-empty list but no `mock_justifications:` line was found' >/dev/null

status1="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['lintdr-ac9']['status'])")"
expect "ac9 setup: fresh bounce recorded needs_classification" "[ '$status1' = needs_classification ]"

# Step 2: re-check with the SHIPPED (fixed) prd-lint.sh -- same PRD file,
# same frontmatter, same lint_id/lint_msg args as before. Frontmatter is
# unchanged; only the lint script differs.
out2="$(LINT_SH="$LINT_NEW" BUILD_STATE_DIR="$T/state" BUILD_MANIFEST="$T/state/manifest.json" JOURNAL="$T/journal.md" \
  "$CSH" bounce-check "$FIX" deferred-acs-missing-justification \
  'deferred_acs is a non-empty list but no `mock_justifications:` line was found')"

expect "AC9: bounce-check reports bounce-cleared" "grep -q 'bounce-cleared' <<<\"\$out2\""
status2="$(python3 -c "import json; print(json.load(open('$T/state/manifest.json'))['prds']['lintdr-ac9']['status'])")"
expect "AC9: status restored to queued (frontmatter never touched)" "[ '$status2' = queued ]"
expect "AC9: journal has the bounce-cleared lint-changed line" \
  "grep -q 'bounce-cleared  lint-changed' '$T/journal.md'"

exit $fail
