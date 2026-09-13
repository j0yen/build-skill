#!/usr/bin/env bash
# laneclaim_ac7_schema_version_present.sh — PRD-build-lane-claim-integrity AC7.
#
# Given any --json output (single-status and bulk shapes), when parsed,
# then schema_version is present and matches the checked-in schema
# (schema_version: 1 per lane-claim.schema.json).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
SCHEMA="$HERE/../scripts/lane-claim.schema.json"
[ -x "$LC" ] || { echo "ac7: $LC not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

# The schema itself pins schema_version as a required const 1 field.
expect "checked-in schema requires schema_version" \
  "jq -e '.required | index(\"schema_version\")' '$SCHEMA' >/dev/null 2>&1"
expect "checked-in schema pins schema_version const to 1" \
  "jq -e '.properties.schema_version.const == 1' '$SCHEMA' >/dev/null 2>&1"

T="$(mktemp -d "${TMPDIR:-/tmp}/laneclaim-ac7.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
cat > "$T/clone/build-queue/PRD-ac7.md" <<'EOF'
# PRD: ac7
- Status: queued
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null
PRD="$T/clone/build-queue/PRD-ac7.md"

# Free (no claim) status --json still carries schema_version.
free_json=$("$LC" status "$PRD" --json)
expect "free-status --json carries schema_version==1" \
  "echo '$free_json' | jq -e '.schema_version == 1' >/dev/null 2>&1"

"$LC" claim "$PRD" redbaron >/dev/null
claimed_json=$("$LC" status "$PRD" --json)
expect "claimed-status --json carries schema_version==1" \
  "echo '$claimed_json' | jq -e '.schema_version == 1' >/dev/null 2>&1"

bulk=$("$LC" --json --prd-dir "$T/clone")
expect "bulk --json carries schema_version==1" \
  "echo '$bulk' | jq -e '.schema_version == 1' >/dev/null 2>&1"

alias_out=$("$LC" claims --prd-dir "$T/clone")
expect "'claims' alias output carries schema_version==1" \
  "echo '$alias_out' | jq -e '.schema_version == 1' >/dev/null 2>&1"

exit $fail
