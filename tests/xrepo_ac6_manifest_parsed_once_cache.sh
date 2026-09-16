#!/usr/bin/env bash
# tests/xrepo_ac6_manifest_parsed_once_cache.sh — PRD-build-cross-repo-
# commit-gate requirement 5 (P1) / AC6: "Given two lands in one tick, When
# both call gated-targets.sh, Then the manifest is parsed once (cache hit
# journaled or counted)." Exercised directly against gated-targets.sh
# (both worktree-extend.sh's cmd_land and main-push-gate.sh call it the
# same way) — a fresh cache directory sees exactly one `cache  miss` for
# the first call and a `cache  hit` for every subsequent call against the
# SAME (unchanged) manifest, whether the call is `list` or `is-gated`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GATED_TARGETS="$HERE/../scripts/gated-targets.sh"
[ -x "$GATED_TARGETS" ] || { echo "selftest: $GATED_TARGETS not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq not on \$PATH, cannot run" >&2; exit 2; }

fail=0
expect() {
  local label="$1" cond="$2"
  if eval "$cond"; then echo "ok  $label"; else echo "FAIL $label ($cond)" >&2; fail=1; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/xrepo-ac6-selftest.XXXXXX")"
trap '[ -n "${XREPO_AC6_SELFTEST_KEEP:-}" ] || rm -rf "$T"' EXIT

REPO="$T/gated-repo"
mkdir -p "$REPO"
RP="$(cd "$REPO" && pwd -P)"

MANIFEST="$T/manifest.json"
jq -n --arg t "$RP" '{prds: {"owner-one": {build_target: "rust-extend", build_into: $t}}, built_at: "x"}' > "$MANIFEST"

export BUILD_MANIFEST="$MANIFEST"
export BUILD_STATE_DIR="$T/state"
export BUILD_JOURNAL_ROOT="$T/journal"

count_lines() {
  local f="$T/journal/$(date -u +%F).md"
  [ -f "$f" ] || { echo 0; return; }
  grep -c "  gated-targets  cache  $1  " "$f" 2>/dev/null
}

echo "=== AC6: manifest parsed once across repeated calls in one tick ==="
"$GATED_TARGETS" list >/dev/null
expect "call 1 (list): exactly one miss so far" "[ \"\$(count_lines miss)\" -eq 1 ]"
expect "call 1 (list): zero hits so far" "[ \"\$(count_lines hit)\" -eq 0 ]"

"$GATED_TARGETS" is-gated "$REPO" >/dev/null
"$GATED_TARGETS" list --explain >/dev/null
"$GATED_TARGETS" is-gated "$T/some/other/path" >/dev/null 2>&1 || true

expect "calls 2-4: still exactly one miss total (manifest parsed once)" "[ \"\$(count_lines miss)\" -eq 1 ]"
expect "calls 2-4: three hits recorded (cache reused, never re-parsed)" "[ \"\$(count_lines hit)\" -eq 3 ]"

# A manifest CHANGE invalidates the cache — one more miss, not a hit.
sleep 1
jq '.prds["owner-two"] = {build_target:"rust-extend", build_into:"/tmp/whatever"}' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
"$GATED_TARGETS" list >/dev/null
expect "manifest change: a second miss is recorded" "[ \"\$(count_lines miss)\" -eq 2 ]"
expect "manifest change: hit count unchanged by the miss" "[ \"\$(count_lines hit)\" -eq 3 ]"

echo "-----"
if [ "$fail" -eq 0 ]; then
  echo "xrepo_ac6: ALL PASS"
else
  echo "xrepo_ac6: assertion(s) FAILED"
fi
exit "$fail"
