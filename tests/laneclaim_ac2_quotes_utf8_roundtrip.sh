#!/usr/bin/env bash
# laneclaim_ac2_quotes_utf8_roundtrip.sh — PRD-build-lane-claim-integrity AC2.
#
# Given claims containing double quotes and UTF-8 in the prd path, when
# --json runs, then output parses and round-trips the values exactly
# (built entirely by jq, never string interpolation).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/../scripts/lane-claim.sh"
[ -x "$LC" ] || { echo "ac2: $LC not executable" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/laneclaim-ac2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
mkdir -p "$T/clone/build-queue"
git -C "$T/clone" commit -q --allow-empty -m init
git -C "$T/clone" push -q origin master 2>/dev/null || git -C "$T/clone" push -q origin main 2>/dev/null

QUOTE_PRD="$T/clone/build-queue/PRD-quote\"embed.md"
cat > "$QUOTE_PRD" <<'EOF'
# PRD: quote-embed
- Status: queued
- build_target: shell
- build_priority: high
EOF
UTF8_PRD="$T/clone/build-queue/PRD-caf\xc3\xa9-utf8.md"
UTF8_PRD=$(printf "$UTF8_PRD")
cat > "$UTF8_PRD" <<'EOF'
# PRD: utf8
- Status: queued
- build_target: shell
- build_priority: high
EOF
git -C "$T/clone" add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m add-quote-utf8-fixtures
git -C "$T/clone" push -q origin "$(git -C "$T/clone" symbolic-ref --short HEAD)"

"$LC" claim "$QUOTE_PRD" redbaron >/dev/null
"$LC" claim "$UTF8_PRD" redbaron >/dev/null

bulk=$("$LC" --json --prd-dir "$T/clone")
expect "bulk --json with quote/utf8 fixtures is valid JSON" "echo '$bulk' | jq -e . >/dev/null 2>&1"

got_quote=$(echo "$bulk" | jq -r --arg p "$QUOTE_PRD" '.claims[] | select(.prd == $p) | .prd')
expect "quoted-path claim round-trips exactly" "[ \"$got_quote\" = \"$QUOTE_PRD\" ]"

got_utf8=$(echo "$bulk" | jq -r --arg p "$UTF8_PRD" '.claims[] | select(.prd == $p) | .prd')
expect "utf8-path claim round-trips exactly" "[ \"$got_utf8\" = \"$UTF8_PRD\" ]"

exit $fail
