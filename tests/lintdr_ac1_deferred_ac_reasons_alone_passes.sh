#!/usr/bin/env bash
# lintdr_ac1_deferred_ac_reasons_alone_passes.sh —
# PRD-build-prd-lint-deferred-reasons-key AC1.
#
# Given a PRD with `deferred_acs: [10, 11]` and a `deferred_ac_reasons` map
# with non-empty strings for "10" and "11" and no `mock_justifications`
# line, When `prd-lint.sh` runs, Then exit 0 with no
# `deferred-acs-missing-justification` finding. Mirrors the real
# PRD-mcphost-tenant-tables shape (2026-09-15 five-whys).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/build-queue" "$d/visions"
echo "plain vision" > "$d/visions/plain.md"
f="$d/build-queue/PRD-lintdr-ac1.md"
cat > "$f" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- deferred_ac_reasons: {"10": "needs a live deploy restore drill.", "11": "P2 export held until table usage exists."}

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$("$LINT" "$f" --format json 2>/dev/null)"; rc=$?
expect "AC1: prd-lint.sh exits 0" "[ $rc -eq 0 ]"
expect "AC1: no deferred-acs-missing-justification finding" \
  "python3 -c \"import json,sys; d=json.load(sys.stdin)[0]; ids=[x['id'] for x in d['failures']]; sys.exit(0 if 'deferred-acs-missing-justification' not in ids else 1)\" <<<\"\$out\""

exit $fail
