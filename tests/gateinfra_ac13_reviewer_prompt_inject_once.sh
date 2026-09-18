#!/usr/bin/env bash
# tests/gateinfra_ac13_reviewer_prompt_inject_once.sh — PRD-build-gate-infra-
# outcome AC13 route A2 (decision 261f5b2c): the one-shot REVIEWER_PROMPT
# injection fires for exactly one matching branch gate and nothing else.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/../scripts/lib/reviewer-prompt-inject.sh"
fail=0
expect() { local label="$1" cond="$2"; if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi; }
T="$(mktemp -d "${TMPDIR:-/tmp}/rpinject.XXXXXX")"; trap 'rm -rf "$T"' EXIT
F="$T/reviewer-prompt-inject-once.json"; J="$T/journal.md"; : >"$J"
arm() { jq -n --arg exp "$1" '{slug_glob:"mcphost-*",reviewer_prompt:"/nonexistent",decision:"261f5b2c",expires_at:$exp}' >"$F"; }
future="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"; past="$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)"

arm "$future"
expect "main scope untouched"      '[ -z "$(reviewer_prompt_inject_once main mcphost-x "$F" "$J")" ] && [ -f "$F" ]'
expect "non-matching slug untouched" '[ -z "$(reviewer_prompt_inject_once branch synthorg-x "$F" "$J")" ] && [ -f "$F" ]'
expect "missing file is a no-op"   '[ -z "$(reviewer_prompt_inject_once branch mcphost-x "$T/nope.json" "$J")" ]'
out="$(reviewer_prompt_inject_once branch mcphost-tenant-tables "$F" "$J")"
expect "matching branch gate gets /nonexistent" '[ "$out" = /nonexistent ]'
expect "file consumed"             '[ ! -f "$F" ] && ls "$T"/*.consumed-*.json >/dev/null 2>&1'
expect "consumed record names slug" 'jq -e ".consumed_by_slug==\"mcphost-tenant-tables\"" "$T"/*.consumed-*.json >/dev/null'
expect "journal line written"      'grep -q "mcphost-tenant-tables  gate  reviewer-prompt-injected  once  (decision=261f5b2c" "$J"'
expect "second gate gets nothing"  '[ -z "$(reviewer_prompt_inject_once branch mcphost-wasm-kind "$F" "$J")" ]'

arm "$past"
expect "expired file injects nothing" '[ -z "$(reviewer_prompt_inject_once branch mcphost-x "$F" "$J")" ]'
expect "expired file renamed"      '[ ! -f "$F" ] && ls "$T"/*.expired-*.json >/dev/null 2>&1 && grep -q "reviewer-prompt-inject  expired" "$J"'

# extend-gate.sh wiring: the hook sources the lib and consults the file.
expect "extend-gate sources lib"   'grep -q "source \"\$BUILD_SCRIPTS/lib/reviewer-prompt-inject.sh\"" "$HERE/../scripts/extend-gate.sh"'
expect "extend-gate reads STATE_DIR file" 'grep -q "REVIEWER_PROMPT_INJECT_ONCE:-\$STATE_DIR/reviewer-prompt-inject-once.json" "$HERE/../scripts/extend-gate.sh"'
[ "$fail" -eq 0 ] && echo "PASS gateinfra_ac13_reviewer_prompt_inject_once" || { echo "FAIL gateinfra_ac13_reviewer_prompt_inject_once" >&2; exit 1; }
