#!/usr/bin/env bash
# lintdr_ac3_partial_reasons_names_missing_number.sh —
# PRD-build-prd-lint-deferred-reasons-key AC3.
#
# Given `deferred_acs: [10, 11]` and `deferred_ac_reasons: {"10": "..."}`,
# When `prd-lint.sh` runs, Then it fails `deferred-acs-reason-missing` and
# the message contains `11`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/../scripts/prd-lint.sh"
[ -x "$LINT" ] || { echo "FAIL: $LINT not executable" >&2; exit 2; }

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/build-queue" "$d/visions"
echo "plain vision" > "$d/visions/plain.md"
f="$d/build-queue/PRD-lintdr-ac3.md"
cat > "$f" <<'EOF'
- Status: queued
- build_target: shell
- Vision: visions/plain.md
- deferred_acs: [10, 11]
- deferred_ac_reasons: {"10": "needs a live deploy restore drill."}

## Acceptance criteria

1. P0 — Given a, When b, Then c.
EOF

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

out="$("$LINT" "$f" --format json 2>/dev/null)"; rc=$?
expect "AC3: prd-lint.sh exits 1" "[ $rc -eq 1 ]"
msg="$(python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print(next((x['message'] for x in d['failures'] if x['id']=='deferred-acs-reason-missing'), ''))" <<<"$out")"
expect "AC3: deferred-acs-reason-missing fires" "[ -n \"$msg\" ]"
expect "AC3: message contains 11" "grep -q '11' <<<\"\$msg\""
expect "AC3: message does not also claim 10 is missing" "! grep -q '10' <<<\"\$msg\""

exit $fail
