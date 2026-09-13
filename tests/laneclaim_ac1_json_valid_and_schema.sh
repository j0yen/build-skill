#!/usr/bin/env bash
# laneclaim_ac1_json_valid_and_schema.sh — PRD-build-lane-claim-integrity AC1.
#
# Given the current script, when the selftest reproduces the invalid
# --json output (pinned as a fixture: the pre-fix "stale" field was a
# bare word, not a JSON boolean, so jq -e rejected EVERY invocation) and
# pins it, then the fixed script's output on the same state passes
# `jq -e` with the checked-in schema.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
SCHEMA="$HERE/../scripts/lane-claim.schema.json"
[ -x "$LC" ] || { echo "ac1: $LC not executable" >&2; exit 2; }
[ -f "$SCHEMA" ] || { echo "ac1: $SCHEMA missing" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# Reproduce the pre-fix shape first (AC1's own reproduction requirement):
# an unquoted bare word for "stale" made every --json invocation invalid
# JSON, not just adversarial ones.
broken_fixture='{"claimed":true,"lane":"carbon","ts":"2026-09-01T00:00:00Z","age_seconds":99,"stale":yes}'
if echo "$broken_fixture" | jq -e . >/dev/null 2>&1; then
  echo "FAIL ac1: pinned pre-fix fixture was expected to be invalid JSON" >&2
  fail=1
else
  echo "ok  ac1: pinned pre-fix fixture reproduces the invalid-JSON defect"
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/laneclaim-ac1.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-ac1.md" <<'EOF'
# PRD: ac1
- Status: queued
- build_target: shell
- build_into: /tmp/laneclaim-ac1-target
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null
PRD="$T/clone/build-queue/PRD-ac1.md"

"$LC" claim "$PRD" redbaron >/dev/null

json=$("$LC" status "$PRD" --json)
expect "status --json is valid JSON" "echo '$json' | jq -e . >/dev/null 2>&1"
expect "status --json carries schema_version==1" "echo '$json' | jq -e '.schema_version == 1' >/dev/null 2>&1"
python3 -c '
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
doc = json.loads(sys.argv[2])
jsonschema.validate(instance=doc, schema=schema)
' "$SCHEMA" "$json" \
  && echo "ok  status --json validates against the checked-in schema" \
  || { echo "FAIL status --json failed schema validation: $json" >&2; fail=1; }

bulk=$("$LC" --json --prd-dir "$T/clone")
expect "bulk --json is valid JSON" "echo '$bulk' | jq -e . >/dev/null 2>&1"
expect "bulk --json has schema_version + claims array" \
  "echo '$bulk' | jq -e '.schema_version == 1 and (.claims | type == \"array\")' >/dev/null 2>&1"
python3 -c '
import json, sys
import jsonschema
schema = json.load(open(sys.argv[1]))
doc = json.loads(sys.argv[2])
jsonschema.validate(instance=doc, schema=schema)
' "$SCHEMA" "$bulk" \
  && echo "ok  bulk --json validates against the checked-in schema" \
  || { echo "FAIL bulk --json failed schema validation: $bulk" >&2; fail=1; }

exit $fail
