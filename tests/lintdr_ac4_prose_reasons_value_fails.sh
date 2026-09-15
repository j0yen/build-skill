#!/usr/bin/env bash
# lintdr_ac4_prose_reasons_value_fails.sh —
# PRD-build-prd-lint-deferred-reasons-key AC4.
#
# Given `deferred_ac_reasons: see below`, When `prd-lint.sh` runs, Then it
# fails `deferred-acs-reasons-prose`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/build-queue" "$d/visions"
echo "plain vision" > "$d/visions/plain.md"
f="$d/build-queue/PRD-lintdr-ac4.md"
cat > "$f" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- deferred_ac_reasons: see below

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$("$LINT" "$f" --format json 2>/dev/null)"; rc=$?
expect "AC4: prd-lint.sh exits 1" "[ $rc -eq 1 ]"
expect "AC4: deferred-acs-reasons-prose fires" \
  "python3 -c \"import json,sys; d=json.load(sys.stdin)[0]; sys.exit(0 if 'deferred-acs-reasons-prose' in [x['id'] for x in d['failures']] else 1)\" <<<\"\$out\""

exit $fail
