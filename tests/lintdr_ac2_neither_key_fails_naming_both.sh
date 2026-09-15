#!/usr/bin/env bash
# lintdr_ac2_neither_key_fails_naming_both.sh —
# PRD-build-prd-lint-deferred-reasons-key AC2.
#
# Given a PRD with `deferred_acs: [10, 11]` and neither `mock_justifications`
# nor `deferred_ac_reasons`, When `prd-lint.sh` runs, Then it fails
# `deferred-acs-missing-justification` and the message names both accepted
# keys.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/build-queue" "$d/visions"
echo "plain vision" > "$d/visions/plain.md"
f="$d/build-queue/PRD-lintdr-ac2.md"
cat > "$f" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$("$LINT" "$f" --format json 2>/dev/null)"; rc=$?
expect "AC2: prd-lint.sh exits 1" "[ $rc -eq 1 ]"
msg="$(python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print(next((x['message'] for x in d['failures'] if x['id']=='deferred-acs-missing-justification'), ''))" <<<"$out")"
# Written to a file, not interpolated into an eval'd string -- the real
# message contains backticked key names, and eval would re-parse those as
# command substitution if the raw value were spliced into $cond.
msgfile="$d/msg.txt"; printf '%s' "$msg" > "$msgfile"
expect "AC2: deferred-acs-missing-justification fires" "[ -s '$msgfile' ]"
expect "AC2: message names mock_justifications" "grep -q 'mock_justifications' '$msgfile'"
expect "AC2: message names deferred_ac_reasons" "grep -q 'deferred_ac_reasons' '$msgfile'"

exit $fail
